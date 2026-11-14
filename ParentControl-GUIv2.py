import gi
gi.require_version('Gtk', '3.0')
from gi.repository import Gtk, Gdk, GLib
import logging
import sys
import os
import glob
import traceback

# Standardized logging setup
logging.basicConfig(
    level=logging.DEBUG,
    format='%(asctime)s - [%(levelname)s] - %(message)s',
    handlers=[logging.StreamHandler(sys.stdout)]
)

class ParentControlApp(Gtk.Window):
    def __init__(self):
        super().__init__(title="ParentControl - Admin Interface")
        self.set_default_size(850, 650)
        self.set_border_width(10)
        
        # Main vertical box to hold menu and notebook
        self.vbox = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        self.add(self.vbox)

        self._create_menu()
        
        self.notebook = Gtk.Notebook()
        self.vbox.pack_start(self.notebook, True, True, 0)

        self._build_acl_tab()
        self._build_network_tab()
        self._build_rwx_tab()
        self._build_apps_tab()
        self._build_queue_tab()
        self._build_auto_tab()
        
        logging.info("ParentControl GTK3 GUI initialized.")

    def _create_menu(self):
        menubar = Gtk.MenuBar()
        
        # File Menu
        file_menu_item = Gtk.MenuItem(label="File")
        file_menu = Gtk.Menu()
        file_menu_item.set_submenu(file_menu)
        
        exit_item = Gtk.MenuItem(label="Exit")
        exit_item.connect("activate", Gtk.main_quit)
        file_menu.append(exit_item)
        
        # Help Menu
        help_menu_item = Gtk.MenuItem(label="Help")
        help_menu = Gtk.Menu()
        help_menu_item.set_submenu(help_menu)
        
        about_item = Gtk.MenuItem(label="About")
        about_item.connect("activate", self._show_about)
        help_menu.append(about_item)
        
        menubar.append(file_menu_item)
        menubar.append(help_menu_item)
        
        self.vbox.pack_start(menubar, False, False, 0)

    # --- Helper to create TreeViews for lists ---
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

    # --- Tab Builders ---
    def _build_acl_tab(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        box.set_border_width(10)
        
        # Input Area
        input_frame = Gtk.Frame(label="Add New URL / IP")
        input_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=5)
        input_box.set_border_width(10)
        input_frame.add(input_box)
        
        self.acl_entry = Gtk.Entry()
        input_box.pack_start(self.acl_entry, True, True, 0)
        
        btn_white = Gtk.Button(label="Whitelist")
        btn_white.connect("clicked", lambda x: self._add_acl_entry("whitelist"))
        input_box.pack_start(btn_white, False, False, 0)
        
        btn_black = Gtk.Button(label="Blacklist")
        btn_black.connect("clicked", lambda x: self._add_acl_entry("blacklist"))
        input_box.pack_start(btn_black, False, False, 0)
        
        box.pack_start(input_frame, False, False, 0)

        # List Area
        list_frame = Gtk.Frame(label="Current Access Control List")
        self.acl_store, self.acl_tree, scroll = self._create_list_view("Rules")
        list_frame.add(scroll)
        box.pack_start(list_frame, True, True, 0)

        # Action Area
        btn_remove = Gtk.Button(label="Remove Selected")
        btn_remove.connect("clicked", self._remove_acl_entry)
        
        action_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL)
        action_box.pack_end(btn_remove, False, False, 0)
        box.pack_start(action_box, False, False, 0)

        self.notebook.append_page(box, Gtk.Label(label="Web & ACL"))

    def _build_network_tab(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        box.set_border_width(10)
        
        # Input Area
        input_frame = Gtk.Frame(label="Block Port")
        input_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=5)
        input_box.set_border_width(10)
        input_frame.add(input_box)
        
        input_box.pack_start(Gtk.Label(label="Port Number:"), False, False, 0)
        self.port_entry = Gtk.Entry()
        input_box.pack_start(self.port_entry, False, False, 0)
        
        input_box.pack_start(Gtk.Label(label="Protocol:"), False, False, 0)
        self.protocol_combo = Gtk.ComboBoxText()
        self.protocol_combo.append_text("TCP")
        self.protocol_combo.append_text("UDP")
        self.protocol_combo.append_text("BOTH")
        self.protocol_combo.set_active(0)
        input_box.pack_start(self.protocol_combo, False, False, 0)
        
        btn_block = Gtk.Button(label="Block Port")
        btn_block.connect("clicked", self._block_port)
        input_box.pack_start(btn_block, False, False, 0)
        
        box.pack_start(input_frame, False, False, 0)

        # List Area
        list_frame = Gtk.Frame(label="Currently Blocked Ports")
        self.net_store, self.net_tree, scroll = self._create_list_view("Blocked Ports")
        list_frame.add(scroll)
        box.pack_start(list_frame, True, True, 0)

        # Action Area
        btn_remove = Gtk.Button(label="Remove Rule")
        btn_remove.connect("clicked", self._remove_port_rule)
        action_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL)
        action_box.pack_end(btn_remove, False, False, 0)
        box.pack_start(action_box, False, False, 0)

        self.notebook.append_page(box, Gtk.Label(label="Network & Ports"))

    def _build_rwx_tab(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        box.set_border_width(10)
        
        input_frame = Gtk.Frame(label="Modify Folder Permissions")
        vbox_input = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=5)
        vbox_input.set_border_width(10)
        input_frame.add(vbox_input)
        
        path_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=5)
        path_box.pack_start(Gtk.Label(label="Target Path:"), False, False, 0)
        self.dir_entry = Gtk.Entry()
        path_box.pack_start(self.dir_entry, True, True, 0)
        
        btn_browse = Gtk.Button(label="Browse")
        btn_browse.connect("clicked", self._browse_directory)
        path_box.pack_start(btn_browse, False, False, 0)
        vbox_input.pack_start(path_box, False, False, 0)
        
        chk_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=15)
        self.chk_r = Gtk.CheckButton(label="Read (R)")
        self.chk_r.set_active(True)
        self.chk_w = Gtk.CheckButton(label="Write (W)")
        self.chk_x = Gtk.CheckButton(label="Execute (X)")
        
        chk_box.pack_start(self.chk_r, False, False, 0)
        chk_box.pack_start(self.chk_w, False, False, 0)
        chk_box.pack_start(self.chk_x, False, False, 0)
        
        btn_apply = Gtk.Button(label="Apply Permissions")
        btn_apply.connect("clicked", self._apply_rwx)
        chk_box.pack_end(btn_apply, False, False, 0)
        
        vbox_input.pack_start(chk_box, False, False, 0)
        box.pack_start(input_frame, False, False, 0)

        list_frame = Gtk.Frame(label="Applied RWX Rules")
        self.rwx_store, self.rwx_tree, scroll = self._create_list_view("Permissions")
        list_frame.add(scroll)
        box.pack_start(list_frame, True, True, 0)

        btn_remove = Gtk.Button(label="Remove Rule")
        btn_remove.connect("clicked", self._remove_rwx_rule)
        action_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL)
        action_box.pack_end(btn_remove, False, False, 0)
        box.pack_start(action_box, False, False, 0)

        self.notebook.append_page(box, Gtk.Label(label="Permissions (RWX)"))

    def _get_installed_apps(self):
        apps = set()
        app_dirs = ['/usr/share/applications/', '/usr/local/share/applications/']
        for directory in app_dirs:
            if not os.path.exists(directory):
                continue
            for filepath in glob.glob(os.path.join(directory, '*.desktop')):
                try:
                    with open(filepath, 'r', encoding='utf-8') as f:
                        for line in f:
                            if line.startswith('Name='):
                                app_name = line.strip().split('=', 1)[1]
                                apps.add(app_name)
                                break
                except Exception as e:
                    logging.warning(f"Failed to read {filepath}: {e}")
        return sorted(list(apps)) if apps else ["No applications found"]

    def _build_apps_tab(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        box.set_border_width(10)
        
        input_frame = Gtk.Frame(label="Manage Application Access")
        input_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=5)
        input_box.set_border_width(10)
        input_frame.add(input_box)
        
        input_box.pack_start(Gtk.Label(label="Select Application:"), False, False, 0)
        
        self.app_combo = Gtk.ComboBoxText()
        for app in self._get_installed_apps():
            self.app_combo.append_text(app)
        input_box.pack_start(self.app_combo, True, True, 0)
        
        self.app_status = Gtk.ComboBoxText()
        self.app_status.append_text("Allow")
        self.app_status.append_text("Block")
        self.app_status.set_active(0)
        input_box.pack_start(self.app_status, False, False, 0)
        
        btn_apply = Gtk.Button(label="Apply Rule")
        btn_apply.connect("clicked", self._apply_app_rule)
        input_box.pack_start(btn_apply, False, False, 0)
        
        box.pack_start(input_frame, False, False, 0)

        list_frame = Gtk.Frame(label="Current Application Rules")
        self.app_store, self.app_tree, scroll = self._create_list_view("Application Rules")
        list_frame.add(scroll)
        box.pack_start(list_frame, True, True, 0)

        btn_remove = Gtk.Button(label="Remove Rule")
        btn_remove.connect("clicked", self._remove_app_rule)
        action_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL)
        action_box.pack_end(btn_remove, False, False, 0)
        box.pack_start(action_box, False, False, 0)

        self.notebook.append_page(box, Gtk.Label(label="Applications"))

    def _build_queue_tab(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        box.set_border_width(10)
        
        queue_frame = Gtk.Frame(label="Pending Requests")
        
        self.queue_store = Gtk.ListStore(str, str, str, str)
        self.queue_tree = Gtk.TreeView(model=self.queue_store)
        
        for i, col_title in enumerate(["User", "Request Type", "Target", "Status"]):
            renderer = Gtk.CellRendererText()
            column = Gtk.TreeViewColumn(col_title, renderer, text=i)
            self.queue_tree.append_column(column)
            
        self.queue_store.append(["student1", "Download File", "homework.pdf", "Pending"])
        self.queue_store.append(["student2", "App Access", "discord", "Pending"])
        
        scroll = Gtk.ScrolledWindow()
        scroll.add(self.queue_tree)
        queue_frame.add(scroll)
        box.pack_start(queue_frame, True, True, 0)
        
        action_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=5)
        btn_approve = Gtk.Button(label="Approve Selected")
        btn_approve.connect("clicked", self._approve_request)
        btn_deny = Gtk.Button(label="Deny Selected")
        btn_deny.connect("clicked", self._deny_request)
        
        action_box.pack_start(btn_approve, False, False, 0)
        action_box.pack_start(btn_deny, False, False, 0)
        box.pack_start(action_box, False, False, 0)

        self.notebook.append_page(box, Gtk.Label(label="Approvals Queue"))

    def _build_auto_tab(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        box.set_border_width(10)
        
        limits_frame = Gtk.Frame(label="Screen Time & Session Limits")
        l_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        l_box.set_border_width(10)
        limits_frame.add(l_box)
        
        l_box.pack_start(Gtk.Label(label="Daily Limit (Hours):"), False, False, 0)
        self.spin_limit = Gtk.SpinButton.new_with_range(0.5, 24.0, 0.5)
        self.spin_limit.set_value(2.0)
        l_box.pack_start(self.spin_limit, False, False, 0)
        
        btn_limit = Gtk.Button(label="Set Limit")
        btn_limit.connect("clicked", self._set_time_limit)
        l_box.pack_start(btn_limit, False, False, 0)
        box.pack_start(limits_frame, False, False, 0)

        self.notebook.append_page(box, Gtk.Label(label="Automation"))

    # --- Backend Logic Placeholders ---
    def _add_acl_entry(self, list_type):
        target = self.acl_entry.get_text().strip()
        if not target:
            self._show_msg(Gtk.MessageType.WARNING, "Input Error", "Please enter a URL or IP.")
            return
        logging.info(f"BACKEND CALL: Adding '{target}' to {list_type}.")
        self.acl_store.append([f"[{list_type.upper()}] {target}"])
        self.acl_entry.set_text("")

    def _remove_acl_entry(self, widget):
        self._remove_selected_from_tree(self.acl_tree, self.acl_store, "ACL")

    def _block_port(self, widget):
        port = self.port_entry.get_text().strip()
        protocol = self.protocol_combo.get_active_text()
        if not port.isdigit():
            self._show_msg(Gtk.MessageType.WARNING, "Input Error", "Port must be a number.")
            return
        logging.info(f"BACKEND CALL: Blocking port {port}/{protocol}.")
        self.net_store.append([f"Blocked: Port {port} ({protocol})"])
        self.port_entry.set_text("")

    def _remove_port_rule(self, widget):
        self._remove_selected_from_tree(self.net_tree, self.net_store, "Network")

    def _browse_directory(self, widget):
        dialog = Gtk.FileChooserDialog(
            title="Select Folder", parent=self, action=Gtk.FileChooserAction.SELECT_FOLDER
        )
        dialog.add_buttons(Gtk.STOCK_CANCEL, Gtk.ResponseType.CANCEL, Gtk.STOCK_OPEN, Gtk.ResponseType.OK)
        if dialog.run() == Gtk.ResponseType.OK:
            self.dir_entry.set_text(dialog.get_filename())
        dialog.destroy()

    def _apply_rwx(self, widget):
        target = self.dir_entry.get_text().strip()
        if not target:
            return
        r = "R" if self.chk_r.get_active() else "-"
        w = "W" if self.chk_w.get_active() else "-"
        x = "X" if self.chk_x.get_active() else "-"
        perms = f"{r}{w}{x}"
        logging.info(f"BACKEND CALL: Setting {perms} on '{target}'.")
        self.rwx_store.append([f"[{perms}] {target}"])
        self.dir_entry.set_text("")

    def _remove_rwx_rule(self, widget):
        self._remove_selected_from_tree(self.rwx_tree, self.rwx_store, "RWX")

    def _apply_app_rule(self, widget):
        app = self.app_combo.get_active_text()
        status = self.app_status.get_active_text()
        if not app:
            return
        logging.info(f"BACKEND CALL: Setting app '{app}' to {status}.")
        self.app_store.append([f"[{status.upper()}] {app}"])

    def _remove_app_rule(self, widget):
        self._remove_selected_from_tree(self.app_tree, self.app_store, "App")

    def _approve_request(self, widget):
        self._update_queue_status("Approved")

    def _deny_request(self, widget):
        self._update_queue_status("Denied")

    def _update_queue_status(self, status):
        selection = self.queue_tree.get_selection()
        model, treeiter = selection.get_selected()
        if treeiter:
            model[treeiter][3] = status
            logging.info(f"BACKEND CALL: {status} request for {model[treeiter][2]}")

    def _set_time_limit(self, widget):
        limit = self.spin_limit.get_value()
        logging.info(f"BACKEND CALL: Setting limit to {limit} hours.")
        self._show_msg(Gtk.MessageType.INFO, "Limit Applied", f"Daily time limit set to {limit} hours.")

    def _remove_selected_from_tree(self, treeview, store, name):
        selection = treeview.get_selection()
        model, treeiter = selection.get_selected()
        if treeiter:
            logging.info(f"BACKEND CALL: Removing {name} rule '{model[treeiter][0]}'")
            store.remove(treeiter)

    def _show_msg(self, msg_type, title, text):
        dialog = Gtk.MessageDialog(
            transient_for=self, flags=0, message_type=msg_type,
            buttons=Gtk.ButtonsType.OK, text=title
        )
        dialog.format_secondary_text(text)
        dialog.run()
        dialog.destroy()

    def _show_about(self, widget):
        self._show_msg(Gtk.MessageType.INFO, "About", "ParentControl GTK3 Admin Interface for Linux Mint.")

if __name__ == "__main__":
    try:
        app = ParentControlApp()
        app.connect("destroy", Gtk.main_quit)
        app.show_all()
        Gtk.main()
    except Exception as e:
        logging.critical(f"Crash: {traceback.format_exc()}")