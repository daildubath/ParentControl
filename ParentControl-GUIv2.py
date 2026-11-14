import gi

gi.require_version('Gtk', '3.0')
from gi.repository import Gtk
import json
import logging
import os
import subprocess
import sys
import glob
import traceback

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s', handlers=[logging.StreamHandler(sys.stdout)])


class ParentControlApp(Gtk.Window):
    def __init__(self):
        super().__init__(title='ParentControl - Admin Interface')
        self.set_default_size(920, 680)
        self.set_border_width(10)

        self.vbox = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        self.add(self.vbox)

        self._create_menu()
        self.notebook = Gtk.Notebook()
        self.vbox.pack_start(self.notebook, True, True, 0)

        self._build_acl_tab()
        self._build_network_tab()
        self._build_rwx_tab()
        self._build_device_tab()
        self._build_status_tab()

        self.refresh_all()
        logging.info('ParentControl GTK3 GUI initialized for installed backend interface.')

    def _create_menu(self):
        menubar = Gtk.MenuBar()

        file_menu_item = Gtk.MenuItem(label='File')
        file_menu = Gtk.Menu()
        file_menu_item.set_submenu(file_menu)
        exit_item = Gtk.MenuItem(label='Exit')
        exit_item.connect('activate', Gtk.main_quit)
        file_menu.append(exit_item)

        help_menu_item = Gtk.MenuItem(label='Help')
        help_menu = Gtk.Menu()
        help_menu_item.set_submenu(help_menu)
        about_item = Gtk.MenuItem(label='About')
        about_item.connect('activate', self._show_about)
        help_menu.append(about_item)

        menubar.append(file_menu_item)
        menubar.append(help_menu_item)
        self.vbox.pack_start(menubar, False, False, 0)

    def _create_list_view(self, column_title):
        liststore = Gtk.ListStore(str)
        treeview = Gtk.TreeView(model=liststore)
        renderer = Gtk.CellRendererText()
        column = Gtk.TreeViewColumn(column_title, renderer, text=0)
        treeview.append_column(column)

        scroll = Gtk.ScrolledWindow()
        scroll.set_policy(Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.AUTOMATIC)
        scroll.add(treeview)
        return liststore, treeview, scroll

    def _script_path(self):
        return '/opt/parentcontrol/bin/pc-ctl.sh'

    def _backend_command(self, module, *args):
        script = self._script_path()
        if not os.path.exists(script):
            raise FileNotFoundError(f'ParentControl backend script not found: {script}')

        if os.geteuid() == 0:
            cmd = [script, '--json', module]
        elif subprocess.run(['which', 'pkexec'], capture_output=True, text=True).returncode == 0:
            cmd = ['pkexec', script, '--json', module]
        elif subprocess.run(['which', 'sudo'], capture_output=True, text=True).returncode == 0:
            cmd = ['sudo', script, '--json', module]
        else:
            cmd = [script, '--json', module]

        cmd.extend(args)
        completed = subprocess.run(cmd, capture_output=True, text=True)

        stdout = (completed.stdout or '').strip()
        stderr = (completed.stderr or '').strip()
        if completed.returncode != 0:
            if stdout:
                raise RuntimeError(stdout)
            if stderr:
                raise RuntimeError(stderr)
            raise RuntimeError(f'Command failed with exit code {completed.returncode}')

        if not stdout:
            return {'status': 'ok', 'data': {}}

        try:
            data = json.loads(stdout)
        except json.JSONDecodeError:
            return {'status': 'ok', 'message': stdout, 'data': {}}

        return data

    def _show_about(self, widget):
        self._show_msg(Gtk.MessageType.INFO, 'About', 'ParentControl GTK3 Admin Interface for Linux Mint 22.3')

    def _show_msg(self, msg_type, title, text):
        dialog = Gtk.MessageDialog(
            transient_for=self,
            flags=0,
            message_type=msg_type,
            buttons=Gtk.ButtonsType.OK,
            text=title,
        )
        dialog.format_secondary_text(text)
        dialog.run()
        dialog.destroy()

    def _remove_selected_from_tree(self, treeview, store):
        selection = treeview.get_selection()
        model, treeiter = selection.get_selected()
        if treeiter:
            store.remove(treeiter)

    def _load_acl_rules(self):
        try:
            result = self._backend_command('acl', '--action', 'list')
            payload = result.get('data', {}) if isinstance(result, dict) else {}
            rules = payload.get('rules', [])
            if not rules:
                white = payload.get('whitelist', [])
                black = payload.get('blacklist', [])
                rules = [{'list': 'whitelist', 'target': x} for x in white] + [{'list': 'blacklist', 'target': x} for x in black]

            self.acl_store.clear()
            for rule in rules:
                label = rule.get('list', 'unknown').lower()
                target = rule.get('target', '')
                if target:
                    self.acl_store.append([f'[{label.upper()}] {target}'])
        except Exception as exc:
            logging.exception('Failed to list ACL rules: %s', exc)
            self._show_msg(Gtk.MessageType.ERROR, 'ACL Error', str(exc))

    def _build_acl_tab(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        box.set_border_width(10)

        input_frame = Gtk.Frame(label='Add New URL / IP')
        input_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=5)
        input_box.set_border_width(10)
        input_frame.add(input_box)

        self.acl_entry = Gtk.Entry()
        self.acl_entry.set_placeholder_text('example.com or 192.168.1.10')
        input_box.pack_start(self.acl_entry, True, True, 0)

        btn_white = Gtk.Button(label='Whitelist')
        btn_white.connect('clicked', lambda _: self._add_acl_entry('whitelist'))
        input_box.pack_start(btn_white, False, False, 0)

        btn_black = Gtk.Button(label='Blacklist')
        btn_black.connect('clicked', lambda _: self._add_acl_entry('blacklist'))
        input_box.pack_start(btn_black, False, False, 0)

        box.pack_start(input_frame, False, False, 0)

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

    def _add_acl_entry(self, list_type):
        target = self.acl_entry.get_text().strip()
        if not target:
            self._show_msg(Gtk.MessageType.WARNING, 'Input Error', 'Please enter a URL, domain, or IP address.')
            return

        try:
            payload = self._backend_command('acl', '--action', 'add', '--list', list_type, '--target', target)
            if payload.get('status') == 'error':
                raise RuntimeError(payload.get('message', 'ACL update failed'))
            self.acl_entry.set_text('')
            self._load_acl_rules()
        except Exception as exc:
            self._show_msg(Gtk.MessageType.ERROR, 'ACL Error', str(exc))

    def _remove_acl_entry(self, widget):
        selection = self.acl_tree.get_selection()
        model, treeiter = selection.get_selected()
        if not treeiter:
            return

        label = model[treeiter][0]
        try:
            list_type, target = self._parse_rule_label(label)
            self._backend_command('acl', '--action', 'remove', '--list', list_type, '--target', target)
            self._remove_selected_from_tree(self.acl_tree, self.acl_store)
        except Exception as exc:
            self._show_msg(Gtk.MessageType.ERROR, 'ACL Error', str(exc))

    def _parse_rule_label(self, row_text):
        cleaned = row_text.strip()
        if cleaned.startswith('['):
            end = cleaned.find(']')
            if end > 0:
                list_type = cleaned[1:end].lower()
                target = cleaned[end + 2:]
                return list_type, target
        return 'blacklist', cleaned

    def _load_ports(self):
        try:
            result = self._backend_command('ports', '--action', 'list')
            payload = result.get('data', {}) if isinstance(result, dict) else {}
            rules = payload.get('blocked_ports', [])
            self.net_store.clear()
            for rule in rules:
                port = rule.get('port')
                proto = rule.get('protocol', 'BOTH')
                if port is not None:
                    self.net_store.append([f'Port {port} / {proto}'])
        except Exception as exc:
            logging.exception('Failed to list port rules: %s', exc)
            self._show_msg(Gtk.MessageType.ERROR, 'Ports Error', str(exc))

    def _build_network_tab(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        box.set_border_width(10)

        input_frame = Gtk.Frame(label='Block Port')
        input_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=5)
        input_box.set_border_width(10)
        input_frame.add(input_box)

        input_box.pack_start(Gtk.Label(label='Port Number:'), False, False, 0)
        self.port_entry = Gtk.Entry()
        self.port_entry.set_placeholder_text('8080')
        input_box.pack_start(self.port_entry, False, False, 0)

        input_box.pack_start(Gtk.Label(label='Protocol:'), False, False, 0)
        self.protocol_combo = Gtk.ComboBoxText()
        for proto in ['TCP', 'UDP', 'BOTH']:
            self.protocol_combo.append_text(proto)
        self.protocol_combo.set_active(0)
        input_box.pack_start(self.protocol_combo, False, False, 0)

        btn_block = Gtk.Button(label='Block Port')
        btn_block.connect('clicked', self._block_port)
        input_box.pack_start(btn_block, False, False, 0)

        box.pack_start(input_frame, False, False, 0)

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

    def _block_port(self, widget):
        port = self.port_entry.get_text().strip()
        proto = self.protocol_combo.get_active_text()
        if not port or not port.isdigit():
            self._show_msg(Gtk.MessageType.WARNING, 'Input Error', 'Port must be a number between 1 and 65535.')
            return
        try:
            self._backend_command('ports', '--action', 'block', '--port', port, '--protocol', proto)
            self.port_entry.set_text('')
            self._load_ports()
        except Exception as exc:
            self._show_msg(Gtk.MessageType.ERROR, 'Ports Error', str(exc))

    def _remove_port_rule(self, widget):
        selection = self.net_tree.get_selection()
        model, treeiter = selection.get_selected()
        if not treeiter:
            return

        value = model[treeiter][0]
        try:
            parts = value.replace('Port ', '').split('/')
            port = parts[0].strip()
            proto = parts[1].strip() if len(parts) > 1 else 'BOTH'
            self._backend_command('ports', '--action', 'unblock', '--port', port, '--protocol', proto)
            self._remove_selected_from_tree(self.net_tree, self.net_store)
        except Exception as exc:
            self._show_msg(Gtk.MessageType.ERROR, 'Ports Error', str(exc))

    def _load_permissions(self):
        try:
            result = self._backend_command('perms', '--action', 'list')
            payload = result.get('data', {}) if isinstance(result, dict) else {}
            rules = payload.get('custom_rules', [])
            self.rwx_store.clear()
            for rule in rules:
                path = rule.get('path')
                perms = rule.get('perms', '---')
                if path:
                    self.rwx_store.append([f'[{perms}] {path}'])
        except Exception as exc:
            logging.exception('Failed to list permissions: %s', exc)
            self._show_msg(Gtk.MessageType.ERROR, 'Permissions Error', str(exc))

    def _build_rwx_tab(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        box.set_border_width(10)

        input_frame = Gtk.Frame(label='Modify Folder Permissions')
        vbox_input = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=5)
        vbox_input.set_border_width(10)
        input_frame.add(vbox_input)

        path_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=5)
        path_box.pack_start(Gtk.Label(label='Target Path:'), False, False, 0)
        self.dir_entry = Gtk.Entry()
        self.dir_entry.set_placeholder_text('/home/student/Downloads')
        path_box.pack_start(self.dir_entry, True, True, 0)

        btn_browse = Gtk.Button(label='Browse')
        btn_browse.connect('clicked', self._browse_directory)
        path_box.pack_start(btn_browse, False, False, 0)
        vbox_input.pack_start(path_box, False, False, 0)

        chk_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=15)
        self.chk_r = Gtk.CheckButton(label='Read (R)')
        self.chk_r.set_active(True)
        self.chk_w = Gtk.CheckButton(label='Write (W)')
        self.chk_x = Gtk.CheckButton(label='Execute (X)')
        chk_box.pack_start(self.chk_r, False, False, 0)
        chk_box.pack_start(self.chk_w, False, False, 0)
        chk_box.pack_start(self.chk_x, False, False, 0)

        btn_apply = Gtk.Button(label='Apply Permissions')
        btn_apply.connect('clicked', self._apply_rwx)
        chk_box.pack_end(btn_apply, False, False, 0)
        vbox_input.pack_start(chk_box, False, False, 0)

        box.pack_start(input_frame, False, False, 0)

        list_frame = Gtk.Frame(label='Applied RWX Rules')
        self.rwx_store, self.rwx_tree, scroll = self._create_list_view('Permissions')
        list_frame.add(scroll)
        box.pack_start(list_frame, True, True, 0)

        action_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL)
        btn_remove = Gtk.Button(label='Remove Rule')
        btn_remove.connect('clicked', self._remove_rwx_rule)
        action_box.pack_end(btn_remove, False, False, 0)
        box.pack_start(action_box, False, False, 0)

        self.notebook.append_page(box, Gtk.Label(label='Permissions (RWX)'))

    def _browse_directory(self, widget):
        dialog = Gtk.FileChooserDialog(
            title='Select Folder',
            parent=self,
            action=Gtk.FileChooserAction.SELECT_FOLDER,
        )
        dialog.add_buttons(Gtk.STOCK_CANCEL, Gtk.ResponseType.CANCEL, Gtk.STOCK_OPEN, Gtk.ResponseType.OK)
        if dialog.run() == Gtk.ResponseType.OK:
            self.dir_entry.set_text(dialog.get_filename())
        dialog.destroy()

    def _apply_rwx(self, widget):
        target = self.dir_entry.get_text().strip()
        if not target:
            self._show_msg(Gtk.MessageType.WARNING, 'Input Error', 'Please enter a target path.')
            return

        perms = []
        perms.append('R' if self.chk_r.get_active() else '-')
        perms.append('W' if self.chk_w.get_active() else '-')
        perms.append('X' if self.chk_x.get_active() else '-')
        perms_str = ''.join(perms)

        try:
            self._backend_command('perms', '--action', 'set', '--path', target, '--perms', perms_str)
            self.dir_entry.set_text('')
            self._load_permissions()
        except Exception as exc:
            self._show_msg(Gtk.MessageType.ERROR, 'Permissions Error', str(exc))

    def _remove_rwx_rule(self, widget):
        selection = self.rwx_tree.get_selection()
        model, treeiter = selection.get_selected()
        if not treeiter:
            return

        value = model[treeiter][0]
        try:
            path = value.split('] ', 1)[-1]
            self._backend_command('perms', '--action', 'remove', '--path', path)
            self._remove_selected_from_tree(self.rwx_tree, self.rwx_store)
        except Exception as exc:
            self._show_msg(Gtk.MessageType.ERROR, 'Permissions Error', str(exc))

    def _load_devices(self):
        try:
            result = self._backend_command('devices', '--action', 'list')
            payload = result.get('data', {}) if isinstance(result, dict) else {}
            device_map = payload.get('devices', {}) if isinstance(payload.get('devices', {}), dict) else {}
            for key in self.device_checks:
                state = bool(device_map.get(key, False))
                self.device_checks[key].set_active(state)
        except Exception as exc:
            logging.exception('Failed to list device rules: %s', exc)
            self._show_msg(Gtk.MessageType.ERROR, 'Devices Error', str(exc))

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

    def _apply_device_rules(self, widget):
        try:
            for key, check in self.device_checks.items():
                self._backend_command('devices', '--action', 'set', '--device', key, '--blocked', 'true' if check.get_active() else 'false')
            self._load_devices()
        except Exception as exc:
            self._show_msg(Gtk.MessageType.ERROR, 'Devices Error', str(exc))

    def _build_status_tab(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        box.set_border_width(10)

        self.status_label = Gtk.Label()
        self.status_label.set_xalign(0)
        self.status_label.set_line_wrap(True)
        box.pack_start(self.status_label, True, True, 0)

        refresh_btn = Gtk.Button(label='Refresh Status')
        refresh_btn.connect('clicked', lambda _: self._refresh_status())
        box.pack_start(refresh_btn, False, False, 0)

        self.notebook.append_page(box, Gtk.Label(label='Status'))

    def _refresh_status(self):
        try:
            result = self._backend_command('status', '--action', 'check')
            payload = result.get('data', {}) if isinstance(result, dict) else {}
            lines = [
                f"Version: {payload.get('version', 'unknown')}",
                f"Restricted user: {payload.get('restricted_user', 'not configured')}",
                f"Admin account ready: {payload.get('admin_account_ready', False)}",
                f"Polkit rule ready: {payload.get('polkit_rule_ready', False)}",
                f"Browser: {payload.get('browser', 'firefox')}",
            ]
            self.status_label.set_text('\n'.join(lines))
        except Exception as exc:
            self._show_msg(Gtk.MessageType.ERROR, 'Status Error', str(exc))

    def refresh_all(self):
        self._load_acl_rules()
        self._load_ports()
        self._load_permissions()
        self._load_devices()
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
