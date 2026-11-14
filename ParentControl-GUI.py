import gi

gi.require_version('Gtk', '3.0')
from gi.repository import Gtk, GLib
import json
import logging
import os
import subprocess
import sys
import traceback

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s', handlers=[logging.StreamHandler(sys.stdout)])


class ParentControlApp(Gtk.Window):
    def __init__(self):
        super().__init__(title='ParentControl - Admin Interface')
        self.set_default_size(950, 750)
        self.set_border_width(10)
        self._loading = False

        self.vbox = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        self.add(self.vbox)

        self._create_menu()
        self.notebook = Gtk.Notebook()
        self.vbox.pack_start(self.notebook, True, True, 0)

        # Build UI Tabs
        self._build_acl_tab()
        self._build_network_tab()
        self._build_rwx_tab()
        self._build_device_tab()
        self._build_apps_tab()
        self._build_queue_tab()
        self._build_maint_tab()
        self._build_setup_tab()
        self._build_status_tab()

        self.refresh_all()
        logging.info('ParentControl GTK3 GUI initialized.')

    def _create_menu(self):
        menubar = Gtk.MenuBar()

        help_menu_item = Gtk.MenuItem(label='Help')
        help_menu = Gtk.Menu()
        help_menu_item.set_submenu(help_menu)

        setup_guide_item = Gtk.MenuItem(label='Setup & Admin Guide')
        setup_guide_item.connect('activate', self._show_admin_guide)
        help_menu.append(setup_guide_item)

        paths_item = Gtk.MenuItem(label='System Paths & Logs')
        paths_item.connect('activate', self._show_paths)
        help_menu.append(paths_item)

        about_item = Gtk.MenuItem(label='About')
        about_item.connect('activate', self._show_about)
        help_menu.append(about_item)

        menubar.append(help_menu_item)
        self.vbox.pack_start(menubar, False, False, 0)

    def _show_admin_guide(self, widget):
        text = (
            "Admin Separation:\n"
            "This application configures a separate 'pcadmin' user. The restricted user has sudo stripped, "
            "and PolicyKit (pkexec) is mapped to authenticate against 'pcadmin'.\n\n"
            "If GUI is unavailable, use CLI setup:\n"
            "sudo pc-ctl setup --action wizard\n\n"
            "Users can request access dynamically using the Desktop shortcut which spawns the Request popup."
        )
        self._show_msg(Gtk.MessageType.INFO, 'Setup & Admin Guide', text)

    def _show_paths(self, widget):
        text = (
            "Configuration: /etc/parentcontrol/config.json\n"
            "Log File: /var/log/parentcontrol/parentcontrol.log\n"
            "Popup Script: /opt/parentcontrol/gui/pc-request-popup.py"
        )
        self._show_msg(Gtk.MessageType.INFO, 'System Paths & Logs', text)

    def _show_about(self, widget):
        self._show_msg(Gtk.MessageType.INFO, 'About', 'ParentControl GTK3 Admin Interface for Linux Mint 22.3\nManage restrictions, rules, and approvals.')

    def _show_msg(self, msg_type, title, text):
        dialog = Gtk.MessageDialog(
            transient_for=self, flags=0, message_type=msg_type,
            buttons=Gtk.ButtonsType.OK, text=title
        )
        dialog.format_secondary_text(text)
        dialog.run()
        dialog.destroy()

    def _script_path(self):
        return '/opt/parentcontrol/bin/pc-ctl.sh'

    def _backend_command(self, module, *args):
        script = self._script_path()
        if not os.path.exists(script):
            raise FileNotFoundError(f'ParentControl backend script not found: {script}')

        cmd = [script, module] + list(args) + ['--json']

        if os.geteuid() != 0:
            cmd = ['pkexec'] + cmd

        completed = subprocess.run(cmd, capture_output=True, text=True)
        stdout = (completed.stdout or '').strip()

        if completed.returncode != 0:
            try:
                data = json.loads(stdout)
                raise RuntimeError(data.get('message', stdout))
            except json.JSONDecodeError:
                raise RuntimeError(stdout or f"Command failed with exit code {completed.returncode}")

        if not stdout:
            return {'status': 'ok', 'data': {}}

        try:
            return json.loads(stdout)
        except json.JSONDecodeError:
            return {'status': 'ok', 'message': stdout, 'data': {}}

    def _create_list_view(self, column_title):
        liststore = Gtk.ListStore(str, str)
        treeview = Gtk.TreeView(model=liststore)
        renderer = Gtk.CellRendererText()
        column = Gtk.TreeViewColumn(column_title, renderer, text=1)
        treeview.append_column(column)
        scroll = Gtk.ScrolledWindow()
        scroll.set_policy(Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.AUTOMATIC)
        scroll.add(treeview)
        return liststore, treeview, scroll

    def _remove_selected_from_tree(self, treeview, store):
        selection = treeview.get_selection()
        model, treeiter = selection.get_selected()
        if treeiter:
            store.remove(treeiter)

    # --- ACL TAB ---
    def _build_acl_tab(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        box.set_border_width(10)

        # Feed Controls
        feed_frame = Gtk.Frame(label='Blocklist Feeds')
        
        self.acl_grid = Gtk.Grid()
        self.acl_grid.set_column_spacing(20)
        self.acl_grid.set_row_spacing(10)
        self.acl_grid.set_border_width(10)
        
        # Create the switches
        self.switch_stevenblack = Gtk.Switch()
        self.switch_phishing = Gtk.Switch()
        
        self.switch_stevenblack.set_valign(Gtk.Align.CENTER)
        self.switch_phishing.set_valign(Gtk.Align.CENTER)
        
        # Connect the toggle signals, passing the feed name as user data
        self.switch_stevenblack.connect("notify::active", self._on_feed_toggle, "stevenblack")
        self.switch_phishing.connect("notify::active", self._on_feed_toggle, "phishing_army")
        
        # Add them to the layout
        self.acl_grid.attach(Gtk.Label(label="StevenBlack Ad/Malware Blocklist", xalign=0), 0, 0, 1, 1)
        self.acl_grid.attach(self.switch_stevenblack, 1, 0, 1, 1)
        
        self.acl_grid.attach(Gtk.Label(label="Phishing Army Blocklist", xalign=0), 0, 1, 1, 1)
        self.acl_grid.attach(self.switch_phishing, 1, 1, 1, 1)

        btn_sync = Gtk.Button(label='Sync Feeds Now')
        btn_sync.connect('clicked', self._sync_acl_feed)
        self.acl_grid.attach(btn_sync, 0, 2, 2, 1)
        
        feed_frame.add(self.acl_grid)
        box.pack_start(feed_frame, False, False, 0)

        # Target Inputs
        input_frame = Gtk.Frame(label='Add New URL / IP')
        input_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=5)
        input_box.set_border_width(10)
        self.acl_entry = Gtk.Entry()
        self.acl_entry.set_placeholder_text('example.com or 192.168.1.10')
        input_box.pack_start(self.acl_entry, True, True, 0)

        for l_type in ['Whitelist', 'Greylist', 'Blacklist']:
            btn = Gtk.Button(label=l_type)
            btn.connect('clicked', lambda _, t=l_type.lower(): self._add_acl_entry(t))
            input_box.pack_start(btn, False, False, 0)

        input_frame.add(input_box)
        box.pack_start(input_frame, False, False, 0)

        # List
        list_frame = Gtk.Frame(label='Current Access Control List')
        self.acl_store, self.acl_tree, scroll = self._create_list_view('Rules')
        list_frame.add(scroll)
        box.pack_start(list_frame, True, True, 0)

        action_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL)
        btn_remove = Gtk.Button(label='Remove Selected')
        btn_remove.connect('clicked', self._remove_acl_entry)
        action_box.pack_end(btn_remove, False, False, 0)
        box.pack_start(action_box, False, False, 0)

        self.notebook.append_page(box, Gtk.Label(label='Web & ACL'))

    def _load_acl_rules(self):
        self._loading = True
        try:
            payload = self._backend_command('acl', '--action', 'list').get('data', {})
            rules = payload.get('rules', [])
            self.acl_store.clear()
            for rule in rules:
                target = rule.get('target', '')
                l_type = rule.get('list', 'unknown').lower()
                if target:
                    self.acl_store.append([f"{l_type}|{target}", f"[{l_type.upper()}] {target}"])
            
            # Safely extract dynamic feed states
            feeds = payload.get("feed_sources", {})
            sb_enabled = feeds.get("stevenblack", {}).get("enabled", False)
            phish_enabled = feeds.get("phishing_army", {}).get("enabled", False)
            
            # Block signals so setting the state programmatically doesn't fire the toggle callback
            self.switch_stevenblack.handler_block_by_func(self._on_feed_toggle)
            self.switch_stevenblack.set_active(sb_enabled)
            self.switch_stevenblack.handler_unblock_by_func(self._on_feed_toggle)
            
            self.switch_phishing.handler_block_by_func(self._on_feed_toggle)
            self.switch_phishing.set_active(phish_enabled)
            self.switch_phishing.handler_unblock_by_func(self._on_feed_toggle)
            
        except Exception as exc:
            logging.exception('ACL Load Error: %s', exc)
        finally:
            self._loading = False

    def _on_feed_toggle(self, switch, gparam, feed_name):
        if self._loading: return
        is_enabled = 'true' if switch.get_active() else 'false'
        try:
            self._backend_command('acl', '--action', 'toggle-feed', '--feed', feed_name, '--enabled', is_enabled)
            logging.info(f"Successfully toggled {feed_name} to {is_enabled}")
            self._load_acl_rules()
        except Exception as exc:
            self._show_msg(Gtk.MessageType.ERROR, 'ACL Feed Error', str(exc))
            
            # Revert the UI switch state if the backend command failed
            switch.handler_block_by_func(self._on_feed_toggle)
            switch.set_active(not switch.get_active())
            switch.handler_unblock_by_func(self._on_feed_toggle)

    def _sync_acl_feed(self, widget):
        try:
            self._backend_command('acl', '--action', 'sync')
            self._load_acl_rules()
            self._show_msg(Gtk.MessageType.INFO, 'Success', 'Feeds synced successfully.')
        except Exception as exc:
            self._show_msg(Gtk.MessageType.ERROR, 'ACL Sync Error', str(exc))

    def _add_acl_entry(self, list_type):
        target = self.acl_entry.get_text().strip()
        if not target: return
        try:
            self._backend_command('acl', '--action', 'add', '--list', list_type, '--target', target)
            self.acl_entry.set_text('')
            self._load_acl_rules()
        except Exception as exc:
            self._show_msg(Gtk.MessageType.ERROR, 'ACL Error', str(exc))

    def _remove_acl_entry(self, widget):
        selection = self.acl_tree.get_selection()
        model, treeiter = selection.get_selected()
        if not treeiter: return
        hidden_val = model[treeiter][0]
        l_type, target = hidden_val.split('|', 1)
        try:
            self._backend_command('acl', '--action', 'remove', '--list', l_type, '--target', target)
            self._remove_selected_from_tree(self.acl_tree, self.acl_store)
        except Exception as exc:
            self._show_msg(Gtk.MessageType.ERROR, 'ACL Error', str(exc))

    # --- PORTS TAB ---
    def _build_network_tab(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        box.set_border_width(10)

        # Presets Block
        preset_frame = Gtk.Frame(label='Quick Presets')
        preset_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=5)
        preset_box.set_border_width(10)
        
        self.preset_combo = Gtk.ComboBoxText()
        preset_box.pack_start(self.preset_combo, True, True, 0)
        
        btn_block_preset = Gtk.Button(label='Block Selected Preset')
        btn_block_preset.connect('clicked', self._block_preset)
        preset_box.pack_start(btn_block_preset, False, False, 0)

        btn_block_all_risky = Gtk.Button(label='Block All Common Risky Ports')
        btn_block_all_risky.connect('clicked', lambda _: self._block_risky_preset('risky'))
        preset_box.pack_start(btn_block_all_risky, False, False, 0)
        
        preset_frame.add(preset_box)
        box.pack_start(preset_frame, False, False, 0)

        # Manual Block
        input_frame = Gtk.Frame(label='Block Port Manually')
        input_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=5)
        input_box.set_border_width(10)
        
        input_box.pack_start(Gtk.Label(label='Port Number:'), False, False, 0)
        self.port_entry = Gtk.Entry()
        self.port_entry.set_placeholder_text('8080')
        input_box.pack_start(self.port_entry, False, False, 0)
        
        expander = Gtk.Expander(label="Protocol Options")
        self.protocol_combo = Gtk.ComboBoxText()
        for proto in ['BOTH', 'TCP', 'UDP']:
            self.protocol_combo.append_text(proto)
        self.protocol_combo.set_active(0)
        expander.add(self.protocol_combo)
        input_box.pack_start(expander, False, False, 0)

        btn_block = Gtk.Button(label='Block Port')
        btn_block.connect('clicked', self._block_port)
        input_box.pack_start(btn_block, False, False, 0)

        input_frame.add(input_box)
        box.pack_start(input_frame, False, False, 0)

        # List
        list_frame = Gtk.Frame(label='Currently Blocked Ports')
        self.net_store, self.net_tree, scroll = self._create_list_view('Blocked Ports')
        list_frame.add(scroll)
        box.pack_start(list_frame, True, True, 0)

        action_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL)
        btn_remove = Gtk.Button(label='Remove Rule')
        btn_remove.connect('clicked', self._remove_port_rule)
        action_box.pack_end(btn_remove, False, False, 0)
        box.pack_start(action_box, False, False, 0)

        self.notebook.append_page(box, Gtk.Label(label='Network & Ports'))

    def _load_ports(self):
        try:
            payload = self._backend_command('ports', '--action', 'list').get('data', {})
            self.net_store.clear()
            for rule in payload.get('blocked_ports', []):
                port = rule.get('port')
                proto = rule.get('protocol', 'BOTH')
                label = rule.get('label', f"Port {port} [{proto}]")
                self.net_store.append([f"{port}|{proto}", label])
            
            # Load presets if empty
            if not len(self.preset_combo.get_model() or []):
                preset_data = self._backend_command('ports', '--action', 'list-presets').get('data', {})
                self.port_preset_ids = []
                for p in preset_data.get('presets', []):
                    self.preset_combo.append_text(p.get('label'))
                    self.port_preset_ids.append(p.get('id'))
                if self.port_preset_ids:
                    self.preset_combo.set_active(0)
        except Exception as exc:
            logging.exception('Ports Load Error: %s', exc)

    def _block_port(self, widget):
        port = self.port_entry.get_text().strip()
        proto = self.protocol_combo.get_active_text() or 'BOTH'
        if not port.isdigit(): return
        try:
            self._backend_command('ports', '--action', 'block', '--port', port, '--protocol', proto)
            self.port_entry.set_text('')
            self._load_ports()
        except Exception as exc:
            self._show_msg(Gtk.MessageType.ERROR, 'Ports Error', str(exc))

    def _block_preset(self, widget):
        idx = self.preset_combo.get_active()
        if idx < 0: return
        p_id = self.port_preset_ids[idx]
        self._block_risky_preset(p_id)

    def _block_risky_preset(self, preset_id):
        try:
            self._backend_command('ports', '--action', 'block-preset', '--preset', preset_id)
            self._load_ports()
        except Exception as exc:
            self._show_msg(Gtk.MessageType.ERROR, 'Ports Preset Error', str(exc))

    def _remove_port_rule(self, widget):
        selection = self.net_tree.get_selection()
        model, treeiter = selection.get_selected()
        if not treeiter: return
        val = model[treeiter][0]
        port, proto = val.split('|')
        try:
            self._backend_command('ports', '--action', 'unblock', '--port', port, '--protocol', proto)
            self._remove_selected_from_tree(self.net_tree, self.net_store)
        except Exception as exc:
            self._show_msg(Gtk.MessageType.ERROR, 'Ports Error', str(exc))

    # --- PERMISSIONS TAB ---
    def _build_rwx_tab(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        box.set_border_width(10)

        # Presets
        preset_frame = Gtk.Frame(label='Home Directory Hardening Presets')
        preset_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=5)
        preset_box.set_border_width(10)
        
        self.rwx_presets = {
            'lock_dotfiles': Gtk.CheckButton(label='Protect shell dotfiles like .bashrc / .profile'),
            'restrict_extra_home_dirs': Gtk.CheckButton(label='Restrict access to other users\' home folders'),
            'noexec_user_dirs': Gtk.CheckButton(label='Block running executables from Downloads, Desktop & /tmp')
        }
        for name, chk in self.rwx_presets.items():
            chk.connect('toggled', lambda c, n=name: self._toggle_rwx_preset(c, n))
            preset_box.pack_start(chk, False, False, 0)
        
        preset_frame.add(preset_box)
        box.pack_start(preset_frame, False, False, 0)

        # Target 
        input_frame = Gtk.Frame(label='Modify Folder Permissions')
        vbox_input = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=5)
        vbox_input.set_border_width(10)

        path_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=5)
        path_box.pack_start(Gtk.Label(label='Target Path:'), False, False, 0)
        self.dir_entry = Gtk.Entry()
        path_box.pack_start(self.dir_entry, True, True, 0)
        
        btn_browse = Gtk.Button(label='Browse')
        btn_browse.connect('clicked', self._browse_directory)
        path_box.pack_start(btn_browse, False, False, 0)
        vbox_input.pack_start(path_box, False, False, 0)

        mode_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=5)
        mode_box.pack_start(Gtk.Label(label='Access Mode:'), False, False, 0)
        
        self.mode_combo = Gtk.ComboBoxText()
        self.modes = ['locked', 'read-only', 'drop-box', 'full']
        self.mode_combo.append_text('Locked (No Access)')
        self.mode_combo.append_text('Read-Only')
        self.mode_combo.append_text('Drop-Box (Write Only)')
        self.mode_combo.append_text('Full Access')
        self.mode_combo.set_active(0)
        mode_box.pack_start(self.mode_combo, False, False, 0)

        btn_apply = Gtk.Button(label='Apply Permissions')
        btn_apply.connect('clicked', self._apply_rwx)
        mode_box.pack_end(btn_apply, False, False, 0)
        vbox_input.pack_start(mode_box, False, False, 0)

        input_frame.add(vbox_input)
        box.pack_start(input_frame, False, False, 0)

        # List
        list_frame = Gtk.Frame(label='Applied Rules')
        self.rwx_store, self.rwx_tree, scroll = self._create_list_view('Permissions')
        list_frame.add(scroll)
        box.pack_start(list_frame, True, True, 0)

        action_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL)
        btn_remove = Gtk.Button(label='Remove Rule')
        btn_remove.connect('clicked', self._remove_rwx_rule)
        action_box.pack_end(btn_remove, False, False, 0)
        box.pack_start(action_box, False, False, 0)

        self.notebook.append_page(box, Gtk.Label(label='Permissions (RWX)'))

def _load_permissions(self):
        self._loading = True
        try:
            payload = self._backend_command('perms', '--action', 'list').get('data', {})
            self.default_browse_dir = payload.get('default_browse_dir', '/home')

            # Presets
            presets = payload.get('presets', {})
            for p_name, chk in self.rwx_presets.items():
                chk.set_active(presets.get(p_name, False))

            # Custom Rules
            self.rwx_store.clear()
            for rule in payload.get('custom_rules', []):
                path = rule.get('path')
                perms = rule.get('perms', '---')
                label = rule.get('label', '')
                display = f'[{perms}] {label} — {path}' if label else f'[{perms}] {path}'
                self.rwx_store.append([path, display])
        except Exception as exc:
            logging.exception('Perms Load Error: %s', exc)
        finally:
            self._loading = False

def _toggle_rwx_preset(self, chk, preset_name):
        if self._loading:
            return
        state = 'true' if chk.get_active() else 'false'
        try:
            self._backend_command('perms', '--action', 'preset', '--name', preset_name, '--enabled', state)
        except Exception as exc:
            self._loading = True
            chk.set_active(not chk.get_active())
            self._loading = False
            self._show_msg(Gtk.MessageType.ERROR, 'Preset Error', str(exc))

def _browse_directory(self, widget):
        dialog = Gtk.FileChooserDialog(
            title='Select Folder', parent=self, action=Gtk.FileChooserAction.SELECT_FOLDER
        )
        dialog.add_buttons(Gtk.STOCK_CANCEL, Gtk.ResponseType.CANCEL, Gtk.STOCK_OPEN, Gtk.ResponseType.OK)
        if hasattr(self, 'default_browse_dir') and os.path.isdir(self.default_browse_dir):
            dialog.set_current_folder(self.default_browse_dir)

        if dialog.run() == Gtk.ResponseType.OK:
            self.dir_entry.set_text(dialog.get_filename())
        dialog.destroy()

def _apply_rwx(self, widget):
        target = self.dir_entry.get_text().strip()
        mode_idx = self.mode_combo.get_active()
        if not target:
            self._show_msg(Gtk.MessageType.WARNING, 'Missing Folder', 'Please enter or browse for a target folder path first.')
            return
        if mode_idx < 0:
            return
        try:
            self._backend_command('perms', '--action', 'set', '--path', target, '--mode', self.modes[mode_idx])
            self.dir_entry.set_text('')
            self._load_permissions()
        except Exception as exc:
            self._show_msg(Gtk.MessageType.ERROR, 'Permissions Error', str(exc))


def _remove_rwx_rule(self, widget):
        selection = self.rwx_tree.get_selection()
        model, treeiter = selection.get_selected()
        if not treeiter: return
        path = model[treeiter][0]
        try:
            self._backend_command('perms', '--action', 'remove', '--path', path)
            self._remove_selected_from_tree(self.rwx_tree, self.rwx_store)
        except Exception as exc:
            self._show_msg(Gtk.MessageType.ERROR, 'Permissions Error', str(exc))

    # --- DEVICES TAB ---
def _build_device_tab(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        box.set_border_width(10)

        frame = Gtk.Frame(label='Hardware Device Controls')
        vbox = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        vbox.set_border_width(10)

        self.device_checks = {
            'usb_storage': Gtk.CheckButton(label='USB Mass Storage'),
            'webcam': Gtk.CheckButton(label='Webcam / Camera'),
            'microphone': Gtk.CheckButton(label='Microphone / Audio Input'),
            'bluetooth': Gtk.CheckButton(label='Bluetooth'),
        }
        for check in self.device_checks.values():
            vbox.pack_start(check, False, False, 0)

        apply_btn = Gtk.Button(label='Apply Device Rules')
        apply_btn.connect('clicked', self._apply_device_rules)
        vbox.pack_start(apply_btn, False, False, 0)
        
        frame.add(vbox)
        box.pack_start(frame, True, True, 0)
        self.notebook.append_page(box, Gtk.Label(label='Devices'))

def _load_devices(self):
        try:
            payload = self._backend_command('devices', '--action', 'list').get('data', {})
            self.device_states = payload.get('devices', {})
            for key, chk in self.device_checks.items():
                chk.set_active(bool(self.device_states.get(key, False)))
        except Exception as exc:
            logging.exception('Devices Load Error: %s', exc)

def _apply_device_rules(self, widget):
        try:
            for key, check in self.device_checks.items():
                active = check.get_active()
                if active != bool(self.device_states.get(key, False)):
                    self._backend_command('devices', '--action', 'set', '--device', key, '--blocked', 'true' if active else 'false')
            self._load_devices()
            self._show_msg(Gtk.MessageType.INFO, 'Success', 'Device rules applied.')
        except Exception as exc:
            self._show_msg(Gtk.MessageType.ERROR, 'Devices Error', str(exc))

   # --- APPS TAB ---
def _build_apps_tab(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        box.set_border_width(10)

        # Settings
        settings_frame = Gtk.Frame(label='Application Settings')
        settings_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        settings_box.set_border_width(10)
        
        self.lock_installers_switch = Gtk.Switch()
        self.lock_installers_switch.connect('notify::active', self._on_lock_installers_toggle)
        settings_box.pack_start(Gtk.Label(label='Lock Software Installers:'), False, False, 0)
        settings_box.pack_start(self.lock_installers_switch, False, False, 0)
        
        btn_scan = Gtk.Button(label='Scan Installed Apps')
        btn_scan.connect('clicked', self._scan_apps)
        settings_box.pack_end(btn_scan, False, False, 0)
        
        settings_frame.add(settings_box)
        box.pack_start(settings_frame, False, False, 0)

        # List (Checkbox, ID, Name, Exec)
        list_frame = Gtk.Frame(label='Application Permissions')
        self.apps_store = Gtk.ListStore(bool, str, str, str)
        self.apps_tree = Gtk.TreeView(model=self.apps_store)
        
        # Checkbox Column (Allow / Block)
        toggle_renderer = Gtk.CellRendererToggle()
        toggle_renderer.connect("toggled", self._on_app_toggled)
        toggle_column = Gtk.TreeViewColumn("Allowed", toggle_renderer, active=0)
        self.apps_tree.append_column(toggle_column)

        # Text Columns
        headers = ["Name", "Exec"]
        for i, header in enumerate(headers):
            renderer = Gtk.CellRendererText()
            column = Gtk.TreeViewColumn(header, renderer, text=i+2) # +2 because index 0 is bool, 1 is hidden ID
            self.apps_tree.append_column(column)

        scroll = Gtk.ScrolledWindow()
        scroll.set_policy(Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.AUTOMATIC)
        scroll.add(self.apps_tree)
        list_frame.add(scroll)
        box.pack_start(list_frame, True, True, 0)

        self.notebook.append_page(box, Gtk.Label(label='Applications'))

def _populate_apps_list(self, apps):
        """Helper to populate the TreeView from an apps array."""
        self.apps_store.clear()
        for app in apps:
            name = app.get('name', '')
            exec_cmd = app.get('exec', '')
            status = app.get('status', 'allow').lower()
            desktop_id = app.get('desktop_id', name)
            
            # True if allowed, False if blocked
            is_allowed = (status != 'block')
            
            if name:
                self.apps_store.append([is_allowed, desktop_id, name, exec_cmd])

def _load_apps(self):
        self._loading = True
        try:
            payload = self._backend_command('apps', '--action', 'list').get('data', {})
            self.lock_installers_switch.set_active(payload.get('lock_installers', False))
            
            apps = payload.get('applications', [])
            self._populate_apps_list(apps)
        except Exception as exc:
            logging.exception('Apps Load Error: %s', exc)
        finally:
            self._loading = False

def _scan_apps(self, widget):
        try:
            payload = self._backend_command('apps', '--action', 'scan').get('data', {})
            apps = payload.get('applications', [])
            self._populate_apps_list(apps)
            self._show_msg(Gtk.MessageType.INFO, 'Success', 'Scan complete.')
        except Exception as exc:
            self._show_msg(Gtk.MessageType.ERROR, 'Scan Error', str(exc))

def _on_app_toggled(self, widget, path):
        # Invert the current boolean value in the store
        current_state = self.apps_store[path][0]
        new_state = not current_state
        self.apps_store[path][0] = new_state
        
        # Get the App Name from column 2 (index 2)
        app_name = self.apps_store[path][2]
        status_str = 'Allow' if new_state else 'Block'
        
        try:
            self._backend_command('apps', '--action', 'set', '--app', app_name, '--status', status_str)
        except Exception as exc:
            # Revert the checkbox if the backend command fails
            self.apps_store[path][0] = current_state
            self._show_msg(Gtk.MessageType.ERROR, 'App Rule Error', str(exc))

def _on_lock_installers_toggle(self, switch, gparam):
        if self._loading: return
        state = 'true' if switch.get_active() else 'false'
        try:
            self._backend_command('apps', '--action', 'lock-installers', '--enabled', state)
        except Exception as exc:
            self._show_msg(Gtk.MessageType.ERROR, 'App Error', str(exc))
    # --- QUEUE TAB ---
def _build_queue_tab(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        box.set_border_width(10)

        # List
        self.queue_store = Gtk.ListStore(str, str, str, str, str, str, str) # ID, Status, Type, Target, Reason, User, Created
        self.queue_tree = Gtk.TreeView(model=self.queue_store)
        
        headers = ["Status", "Type", "Target", "Reason", "User", "Created At"]
        for i, header in enumerate(headers):
            renderer = Gtk.CellRendererText()
            column = Gtk.TreeViewColumn(header, renderer, text=i+1)
            self.queue_tree.append_column(column)
            
        scroll = Gtk.ScrolledWindow()
        scroll.set_policy(Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.AUTOMATIC)
        scroll.add(self.queue_tree)
        box.pack_start(scroll, True, True, 0)

        action_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=5)
        btn_approve = Gtk.Button(label='Approve')
        btn_approve.connect('clicked', lambda _: self._handle_queue_action('approve'))
        action_box.pack_start(btn_approve, False, False, 0)

        btn_deny = Gtk.Button(label='Deny')
        btn_deny.connect('clicked', lambda _: self._handle_queue_action('deny'))
        action_box.pack_start(btn_deny, False, False, 0)
        
        btn_remove = Gtk.Button(label='Remove Entry')
        btn_remove.connect('clicked', lambda _: self._handle_queue_action('remove'))
        action_box.pack_start(btn_remove, False, False, 0)

        btn_refresh = Gtk.Button(label='Refresh Queue')
        btn_refresh.connect('clicked', lambda _: self._load_queue())
        action_box.pack_end(btn_refresh, False, False, 0)
        
        box.pack_start(action_box, False, False, 0)
        self.notebook.append_page(box, Gtk.Label(label='Approvals Queue'))

def _load_queue(self):
        try:
            payload = self._backend_command('queue', '--action', 'list').get('data', {})
            self.queue_store.clear()
            for req in payload.get('requests', []):
                self.queue_store.append([
                    req.get('id', ''), req.get('status', ''), req.get('type', ''),
                    req.get('target', ''), req.get('reason', ''), req.get('user', ''),
                    req.get('created_at', '')
                ])
        except Exception as exc:
            logging.exception('Queue Load Error: %s', exc)

def _handle_queue_action(self, action):
        selection = self.queue_tree.get_selection()
        model, treeiter = selection.get_selected()
        if not treeiter: return
        req_id = model[treeiter][0]
        try:
            self._backend_command('queue', '--action', action, '--id', req_id)
            self._load_queue()
        except Exception as exc:
            self._show_msg(Gtk.MessageType.ERROR, 'Queue Error', str(exc))

    # --- MAINT TAB ---
def _build_maint_tab(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        box.set_border_width(10)

        # Access & Limits
        limit_frame = Gtk.Frame(label='Screen Time & Accessibility')
        limit_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        limit_box.set_border_width(10)
        
        row1 = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        self.senior_switch = Gtk.Switch()
        self.senior_switch.connect('notify::active', self._on_senior_preset)
        row1.pack_start(Gtk.Label(label='Senior/Dementia Accessibility Preset:'), False, False, 0)
        row1.pack_start(self.senior_switch, False, False, 0)
        limit_box.pack_start(row1, False, False, 0)

        row2 = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        self.time_limit_switch = Gtk.Switch()
        self.time_limit_spin = Gtk.SpinButton.new_with_range(0.5, 24.0, 0.5)
        btn_apply_time = Gtk.Button(label='Apply Time Limit')
        btn_apply_time.connect('clicked', self._apply_time_limit)
        
        self.used_time_lbl = Gtk.Label(label='Used Today: 0m')
        row2.pack_start(Gtk.Label(label='Daily Screen-Time Limit (Hrs):'), False, False, 0)
        row2.pack_start(self.time_limit_switch, False, False, 0)
        row2.pack_start(self.time_limit_spin, False, False, 0)
        row2.pack_start(btn_apply_time, False, False, 0)
        row2.pack_end(self.used_time_lbl, False, False, 0)
        limit_box.pack_start(row2, False, False, 0)
        
        limit_frame.add(limit_box)
        box.pack_start(limit_frame, False, False, 0)

        # Automation
        auto_frame = Gtk.Frame(label='Automated Maintenance')
        auto_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=5)
        auto_box.set_border_width(10)
        
        self.auto_checks = {
            'auto_updates': Gtk.CheckButton(label='System Updates'),
            'auto_timeshift': Gtk.CheckButton(label='Timeshift Backups'),
            'auto_trash_purge': Gtk.CheckButton(label='Purge Trash')
        }
        for name, chk in self.auto_checks.items():
            chk.connect('toggled', lambda c, n=name: self._toggle_auto_feature(c, n))
            auto_box.pack_start(chk, False, False, 0)
            
        btn_run_maint = Gtk.Button(label='Run Maintenance Now')
        btn_run_maint.connect('clicked', lambda _: self._run_maint_now())
        auto_box.pack_start(btn_run_maint, False, False, 0)

        auto_frame.add(auto_box)
        box.pack_start(auto_frame, False, False, 0)
        self.notebook.append_page(box, Gtk.Label(label='Automation & Access'))

def _load_maint(self):
        self._loading = True
        try:
            payload = self._backend_command('maint', '--action', 'list').get('data', {})
            self.senior_switch.set_active(payload.get('senior_preset', False))
            self.time_limit_switch.set_active(payload.get('time_limit_enabled', False))
            self.time_limit_spin.set_value(float(payload.get('daily_limit_hours', 2.0)))
            self.used_time_lbl.set_text(f"Used Today: {payload.get('used_minutes_today', 0)}m")
            
            for key, chk in self.auto_checks.items():
                chk.set_active(payload.get(key, False))
        except Exception as exc:
            logging.exception('Maint Load Error: %s', exc)
        finally:
            self._loading = False

def _on_senior_preset(self, switch, gparam):
        if self._loading: return
        state = 'true' if switch.get_active() else 'false'
        try:
            self._backend_command('maint', '--action', 'senior-preset', '--enabled', state)
        except Exception as exc:
            self._show_msg(Gtk.MessageType.ERROR, 'Preset Error', str(exc))

def _apply_time_limit(self, widget):
        state = 'true' if self.time_limit_switch.get_active() else 'false'
        hours = str(self.time_limit_spin.get_value())
        try:
            self._backend_command('maint', '--action', 'time-limit', '--enabled', state, '--hours', hours)
            self._show_msg(Gtk.MessageType.INFO, 'Success', 'Time limit saved.')
            self._load_maint()
        except Exception as exc:
            self._show_msg(Gtk.MessageType.ERROR, 'Time Limit Error', str(exc))

def _toggle_auto_feature(self, chk, feature):
        if self._loading: return
        state = 'true' if chk.get_active() else 'false'
        try:
            self._backend_command('maint', '--action', 'set-auto', '--feature', feature, '--enabled', state)
        except Exception as exc:
            self._show_msg(Gtk.MessageType.ERROR, 'Maint Error', str(exc))

def _run_maint_now(self):
        try:
            # Backend handles detachment now; will return near-instantly without freezing GTK
            self._backend_command('maint', '--action', 'run-now')
            self._show_msg(Gtk.MessageType.INFO, 'Success', 'Maintenance task triggered successfully and is running in the background.')
        except Exception as exc:
            self._show_msg(Gtk.MessageType.ERROR, 'Maint Error', str(exc))

    # --- SETUP TAB ---
def _build_setup_tab(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        box.set_border_width(10)

        # Admin Setup
        admin_frame = Gtk.Frame(label='Admin Separation')
        admin_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=5)
        admin_box.set_border_width(10)
        
        row1 = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=5)
        row1.pack_start(Gtk.Label(label='Target Restricted User:'), False, False, 0)
        self.setup_user_entry = Gtk.Entry()
        row1.pack_start(self.setup_user_entry, True, True, 0)
        admin_box.pack_start(row1, False, False, 0)

        row2 = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=5)
        row2.pack_start(Gtk.Label(label='pcadmin Password:'), False, False, 0)
        self.setup_pw_entry = Gtk.Entry()
        self.setup_pw_entry.set_visibility(False)
        row2.pack_start(self.setup_pw_entry, True, True, 0)
        
        row2.pack_start(Gtk.Label(label='Confirm:'), False, False, 0)
        self.setup_pw2_entry = Gtk.Entry()
        self.setup_pw2_entry.set_visibility(False)
        row2.pack_start(self.setup_pw2_entry, True, True, 0)
        admin_box.pack_start(row2, False, False, 0)

        self.strip_sudo_chk = Gtk.CheckButton(label='Strip sudo/admin rights from restricted user')
        self.strip_sudo_chk.set_active(True)
        admin_box.pack_start(self.strip_sudo_chk, False, False, 0)

        btn_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=5)
        btn_apply = Gtk.Button(label='Apply Admin Setup')
        btn_apply.connect('clicked', self._apply_admin_setup)
        btn_row.pack_start(btn_apply, False, False, 0)
        
        btn_restore = Gtk.Button(label='Restore User Sudo')
        btn_restore.connect('clicked', self._restore_user_sudo)
        btn_row.pack_end(btn_restore, False, False, 0)
        admin_box.pack_start(btn_row, False, False, 0)
        
        admin_frame.add(admin_box)
        box.pack_start(admin_frame, False, False, 0)

        # Contact Setup
        contact_frame = Gtk.Frame(label='Caregiver Contact Info (Shown on User Access Popup)')
        contact_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=5)
        contact_box.set_border_width(10)
        
        self.contact_entries = {}
        for field in ['Name', 'Phone', 'Email', 'Note']:
            row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=5)
            row.pack_start(Gtk.Label(label=f'{field}:'), False, False, 0)
            entry = Gtk.Entry()
            self.contact_entries[field.lower()] = entry
            row.pack_start(entry, True, True, 0)
            contact_box.pack_start(row, False, False, 0)

        btn_save_contact = Gtk.Button(label='Save Contact Info')
        btn_save_contact.connect('clicked', self._save_contact)
        contact_box.pack_start(btn_save_contact, False, False, 0)

        contact_frame.add(contact_box)
        box.pack_start(contact_frame, False, False, 0)
        
        self.notebook.append_page(box, Gtk.Label(label='Setup & Caregiver'))

def _load_setup(self):
        try:
            payload = self._backend_command('status', '--action', 'check').get('data', {})
            self.setup_user_entry.set_text(payload.get('restricted_user', ''))
            contact = payload.get('admin_contact', {})
            self.contact_entries['name'].set_text(contact.get('name', ''))
            self.contact_entries['phone'].set_text(contact.get('phone', ''))
            self.contact_entries['email'].set_text(contact.get('email', ''))
            self.contact_entries['note'].set_text(contact.get('note', ''))
        except Exception as exc:
            logging.exception('Setup Load Error: %s', exc)

def _apply_admin_setup(self, widget):
        user = self.setup_user_entry.get_text().strip()
        pw1 = self.setup_pw_entry.get_text()
        pw2 = self.setup_pw2_entry.get_text()
        strip = 'true' if self.strip_sudo_chk.get_active() else 'false'
        
        if not user or not pw1:
            self._show_msg(Gtk.MessageType.WARNING, 'Input Error', 'User and Password required.')
            return
        if pw1 != pw2:
            self._show_msg(Gtk.MessageType.WARNING, 'Input Error', 'Passwords do not match.')
            return
            
        try:
            self._backend_command('setup', '--action', 'provision-admin', '--user', user, '--admin-password', pw1, '--strip-user-sudo', strip)
            self.setup_pw_entry.set_text('')
            self.setup_pw2_entry.set_text('')
            self._show_msg(Gtk.MessageType.INFO, 'Success', 'Admin provisioned successfully.')
            self.refresh_all()
        except Exception as exc:
            self._show_msg(Gtk.MessageType.ERROR, 'Setup Error', str(exc))

def _restore_user_sudo(self, widget):
        try:
            self._backend_command('setup', '--action', 'restore-admin')
            self._show_msg(Gtk.MessageType.INFO, 'Success', 'User sudo restored.')
        except Exception as exc:
            self._show_msg(Gtk.MessageType.ERROR, 'Restore Error', str(exc))

def _save_contact(self, widget):
        name = self.contact_entries['name'].get_text()
        phone = self.contact_entries['phone'].get_text()
        email = self.contact_entries['email'].get_text()
        note = self.contact_entries['note'].get_text()
        try:
            self._backend_command('setup', '--action', 'set-contact', '--name', name, '--phone', phone, '--email', email, '--note', note)
            self._show_msg(Gtk.MessageType.INFO, 'Success', 'Contact info saved.')
        except Exception as exc:
            self._show_msg(Gtk.MessageType.ERROR, 'Contact Error', str(exc))

    # --- STATUS TAB ---
def _build_status_tab(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        box.set_border_width(10)

        self.status_label = Gtk.Label()
        self.status_label.set_xalign(0)
        self.status_label.set_line_wrap(True)
        box.pack_start(self.status_label, False, False, 0)

        btn_refresh = Gtk.Button(label='Refresh Status')
        btn_refresh.connect('clicked', lambda _: self._refresh_status())
        box.pack_start(btn_refresh, False, False, 0)

        log_frame = Gtk.Frame(label='Audit Logs')
        log_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=5)
        log_box.set_border_width(5)
        
        scroll = Gtk.ScrolledWindow()
        scroll.set_policy(Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.AUTOMATIC)
        self.log_textview = Gtk.TextView()
        self.log_textview.set_editable(False)
        self.log_textview.modify_font(gi.repository.Pango.FontDescription('monospace 10'))
        scroll.add(self.log_textview)
        log_box.pack_start(scroll, True, True, 0)

        log_btn_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=5)
        btn_load_logs = Gtk.Button(label='Load Full Logs')
        btn_load_logs.connect('clicked', self._load_full_logs)
        log_btn_box.pack_start(btn_load_logs, False, False, 0)
        
        btn_clear_logs = Gtk.Button(label='Clear Logs')
        btn_clear_logs.connect('clicked', self._clear_logs)
        log_btn_box.pack_end(btn_clear_logs, False, False, 0)
        
        log_box.pack_start(log_btn_box, False, False, 0)
        log_frame.add(log_box)
        box.pack_start(log_frame, True, True, 0)

        self.notebook.append_page(box, Gtk.Label(label='Status & Logs'))

def _refresh_status(self):
        try:
            payload = self._backend_command('status', '--action', 'check').get('data', {})
            lines = [
                f"Version: {payload.get('version', 'unknown')}",
                f"Restricted user: {payload.get('restricted_user', 'not configured')} (Has sudo: {payload.get('restricted_user_has_sudo', False)})",
                f"Admin user: {payload.get('admin_user', 'not configured')}",
                f"Admin account ready: {payload.get('admin_account_ready', False)}",
                f"Admin password configured: {payload.get('admin_password_configured', False)}",
                f"Polkit rule ready: {payload.get('polkit_rule_ready', False)}",
                f"Senior Preset: {payload.get('senior_preset', False)}",
                f"Log File: {payload.get('log_file', '')}"
            ]
            self.status_label.set_text('\n'.join(lines))
            
            buf = self.log_textview.get_buffer()
            buf.set_text('\n'.join(payload.get('recent_logs', [])))
        except Exception as exc:
            self._show_msg(Gtk.MessageType.ERROR, 'Status Error', str(exc))

def _load_full_logs(self, widget):
        try:
            payload = self._backend_command('logs', '--action', 'read', '--lines', '100').get('data', {})
            buf = self.log_textview.get_buffer()
            buf.set_text('\n'.join(payload.get('logs', [])))
        except Exception as exc:
            self._show_msg(Gtk.MessageType.ERROR, 'Log Error', str(exc))

def _clear_logs(self, widget):
        try:
            self._backend_command('logs', '--action', 'clear')
            self._refresh_status()
        except Exception as exc:
            self._show_msg(Gtk.MessageType.ERROR, 'Log Error', str(exc))

def refresh_all(self):
        self._load_acl_rules()
        self._load_ports()
        self._load_permissions()
        self._load_devices()
        self._load_apps()
        self._load_queue()
        self._load_maint()
        self._load_setup()
        self._refresh_status()

if __name__ == '__main__':
    try:
        app = ParentControlApp()
        app.connect('destroy', Gtk.main_quit)
        app.show_all()
        Gtk.main()
    except Exception:
        logging.critical('Crash: %s', traceback.format_exc())
        raise