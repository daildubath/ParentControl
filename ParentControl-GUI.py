import tkinter as tk
from tkinter import ttk
from tkinter import messagebox
from tkinter import filedialog
import logging
import traceback
import sys
import os
import glob

# Standardized logging setup
logging.basicConfig(
    level=logging.DEBUG,
    format='%(asctime)s - [%(levelname)s] - %(message)s',
    handlers=[
        logging.StreamHandler(sys.stdout)
    ]
)

class ParentControlApp:
    def __init__(self, root):
        self.root = root
        self.root.title("ParentControl - Admin Interface")
        self.root.geometry("850x650")
        self.root.minsize(700, 500)
        
        # Override Tkinter's default error handling to use our standardized logger
        self.root.report_callback_exception = self.handle_gui_exception

        self._create_menu()
        self._create_tabs()

        logging.info("ParentControl GUI initialized.")

    def _create_menu(self):
        menubar = tk.Menu(self.root)
        
        file_menu = tk.Menu(menubar, tearoff=0)
        file_menu.add_command(label="Exit", command=self.root.quit)
        menubar.add_cascade(label="File", menu=file_menu)
        
        help_menu = tk.Menu(menubar, tearoff=0)
        help_menu.add_command(label="About", command=self._show_about)
        help_menu.add_command(label="Help / Instructions", command=self._show_help)
        menubar.add_cascade(label="Help", menu=help_menu)
        
        self.root.config(menu=menubar)

    def _create_tabs(self):
        self.notebook = ttk.Notebook(self.root)
        self.notebook.pack(expand=True, fill='both', padx=10, pady=10)
        
        self.tab_acl = ttk.Frame(self.notebook)
        self.tab_network = ttk.Frame(self.notebook)
        self.tab_rwx = ttk.Frame(self.notebook)
        self.tab_apps = ttk.Frame(self.notebook)
        self.tab_queue = ttk.Frame(self.notebook)
        self.tab_auto = ttk.Frame(self.notebook)
        
        self.notebook.add(self.tab_acl, text="Web & ACL")
        self.notebook.add(self.tab_network, text="Network & Ports")
        self.notebook.add(self.tab_rwx, text="Permissions (RWX)")
        self.notebook.add(self.tab_apps, text="Applications")
        self.notebook.add(self.tab_queue, text="Approvals Queue")
        self.notebook.add(self.tab_auto, text="Automation")

        self._build_acl_tab()
        self._build_network_tab()
        self._build_rwx_tab()
        self._build_apps_tab()
        self._build_queue_tab()
        self._build_auto_tab()

    # --- Tab Builders ---
    def _build_acl_tab(self):
        input_frame = ttk.LabelFrame(self.tab_acl, text="Add New URL / IP")
        input_frame.pack(fill='x', padx=10, pady=10)

        self.acl_entry = ttk.Entry(input_frame, width=50)
        self.acl_entry.pack(side='left', padx=10, pady=10, expand=True, fill='x')

        ttk.Button(input_frame, text="Whitelist", command=lambda: self._add_acl_entry("whitelist")).pack(side='left', padx=5, pady=10)
        ttk.Button(input_frame, text="Blacklist", command=lambda: self._add_acl_entry("blacklist")).pack(side='left', padx=5, pady=10)
        ttk.Button(input_frame, text="Grey List", command=lambda: self._add_acl_entry("greylist")).pack(side='left', padx=5, pady=10)

        list_frame = ttk.LabelFrame(self.tab_acl, text="Current Access Control List")
        list_frame.pack(fill='both', expand=True, padx=10, pady=5)

        scrollbar = ttk.Scrollbar(list_frame)
        scrollbar.pack(side='right', fill='y')

        self.acl_listbox = tk.Listbox(list_frame, yscrollcommand=scrollbar.set, selectmode='extended')
        self.acl_listbox.pack(side='left', fill='both', expand=True, padx=5, pady=5)
        scrollbar.config(command=self.acl_listbox.yview)

        action_frame = ttk.Frame(list_frame)
        action_frame.pack(side='bottom', fill='x', pady=5)
        ttk.Button(action_frame, text="Remove Selected", command=self._remove_acl_entry).pack(side='right', padx=5)

    def _build_network_tab(self):
        port_frame = ttk.LabelFrame(self.tab_network, text="Block Port")
        port_frame.pack(fill='x', padx=10, pady=10)

        ttk.Label(port_frame, text="Port Number:").pack(side='left', padx=5, pady=10)
        self.port_entry = ttk.Entry(port_frame, width=15)
        self.port_entry.pack(side='left', padx=5, pady=10)

        ttk.Label(port_frame, text="Protocol:").pack(side='left', padx=5, pady=10)
        self.protocol_var = tk.StringVar(value="TCP")
        protocol_combo = ttk.Combobox(port_frame, textvariable=self.protocol_var, values=["TCP", "UDP", "BOTH"], width=10, state="readonly")
        protocol_combo.pack(side='left', padx=5, pady=10)

        ttk.Button(port_frame, text="Block Port", command=self._block_port).pack(side='left', padx=15, pady=10)

        list_frame = ttk.LabelFrame(self.tab_network, text="Currently Blocked Ports / Devices")
        list_frame.pack(fill='both', expand=True, padx=10, pady=5)

        scrollbar = ttk.Scrollbar(list_frame)
        scrollbar.pack(side='right', fill='y')

        self.network_listbox = tk.Listbox(list_frame, yscrollcommand=scrollbar.set, selectmode='extended')
        self.network_listbox.pack(side='left', fill='both', expand=True, padx=5, pady=5)
        scrollbar.config(command=self.network_listbox.yview)

        action_frame = ttk.Frame(list_frame)
        action_frame.pack(side='bottom', fill='x', pady=5)
        ttk.Button(action_frame, text="Remove Rule", command=self._remove_port_rule).pack(side='right', padx=5)

    def _build_rwx_tab(self):
        control_frame = ttk.LabelFrame(self.tab_rwx, text="Modify Folder Permissions")
        control_frame.pack(fill='x', padx=10, pady=10)

        dir_frame = ttk.Frame(control_frame)
        dir_frame.pack(fill='x', padx=5, pady=5)
        
        ttk.Label(dir_frame, text="Target Path:").pack(side='left', padx=5)
        self.dir_entry = ttk.Entry(dir_frame, width=40)
        self.dir_entry.pack(side='left', padx=5, expand=True, fill='x')
        ttk.Button(dir_frame, text="Browse", command=self._browse_directory).pack(side='left', padx=5)

        chk_frame = ttk.Frame(control_frame)
        chk_frame.pack(fill='x', padx=5, pady=5)
        
        self.read_var = tk.BooleanVar(value=True)
        self.write_var = tk.BooleanVar(value=False)
        self.exec_var = tk.BooleanVar(value=False)
        
        ttk.Checkbutton(chk_frame, text="Read (R)", variable=self.read_var).pack(side='left', padx=10)
        ttk.Checkbutton(chk_frame, text="Write (W)", variable=self.write_var).pack(side='left', padx=10)
        ttk.Checkbutton(chk_frame, text="Execute (X)", variable=self.exec_var).pack(side='left', padx=10)
        
        ttk.Button(chk_frame, text="Apply Permissions", command=self._apply_rwx).pack(side='right', padx=10)

        list_frame = ttk.LabelFrame(self.tab_rwx, text="Applied RWX Rules")
        list_frame.pack(fill='both', expand=True, padx=10, pady=5)

        scrollbar = ttk.Scrollbar(list_frame)
        scrollbar.pack(side='right', fill='y')

        self.rwx_listbox = tk.Listbox(list_frame, yscrollcommand=scrollbar.set, selectmode='extended')
        self.rwx_listbox.pack(side='left', fill='both', expand=True, padx=5, pady=5)
        scrollbar.config(command=self.rwx_listbox.yview)

        action_frame = ttk.Frame(list_frame)
        action_frame.pack(side='bottom', fill='x', pady=5)
        ttk.Button(action_frame, text="Remove Rule", command=self._remove_rwx_rule).pack(side='right', padx=5)

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
        app_frame = ttk.LabelFrame(self.tab_apps, text="Manage Application Access")
        app_frame.pack(fill='x', padx=10, pady=10)

        ttk.Label(app_frame, text="Select Application:").pack(side='left', padx=5, pady=10)
        
        self.app_combo = ttk.Combobox(app_frame, values=self._get_installed_apps(), width=30)
        self.app_combo.pack(side='left', padx=5, pady=10)

        self.app_status_var = tk.StringVar(value="Allow")
        ttk.Radiobutton(app_frame, text="Allow", variable=self.app_status_var, value="Allow").pack(side='left', padx=5)
        ttk.Radiobutton(app_frame, text="Block", variable=self.app_status_var, value="Block").pack(side='left', padx=5)

        ttk.Button(app_frame, text="Apply Rule", command=self._apply_app_rule).pack(side='left', padx=15, pady=10)

        list_frame = ttk.LabelFrame(self.tab_apps, text="Current Application Rules")
        list_frame.pack(fill='both', expand=True, padx=10, pady=5)

        scrollbar = ttk.Scrollbar(list_frame)
        scrollbar.pack(side='right', fill='y')

        self.app_listbox = tk.Listbox(list_frame, yscrollcommand=scrollbar.set, selectmode='extended')
        self.app_listbox.pack(side='left', fill='both', expand=True, padx=5, pady=5)
        scrollbar.config(command=self.app_listbox.yview)

        action_frame = ttk.Frame(list_frame)
        action_frame.pack(side='bottom', fill='x', pady=5)
        ttk.Button(action_frame, text="Remove Rule", command=self._remove_app_rule).pack(side='right', padx=5)

    def _build_queue_tab(self):
        queue_frame = ttk.LabelFrame(self.tab_queue, text="Pending Requests (Downloads, Uploads, App Access)")
        queue_frame.pack(fill='both', expand=True, padx=10, pady=10)

        columns = ("user", "type", "target", "status")
        self.queue_tree = ttk.Treeview(queue_frame, columns=columns, show="headings")
        self.queue_tree.heading("user", text="User")
        self.queue_tree.heading("type", text="Request Type")
        self.queue_tree.heading("target", text="Target (URL/File/App)")
        self.queue_tree.heading("status", text="Status")
        
        self.queue_tree.column("user", width=100)
        self.queue_tree.column("type", width=120)
        self.queue_tree.column("target", width=300)
        self.queue_tree.column("status", width=100)

        self.queue_tree.pack(side='left', fill='both', expand=True, padx=5, pady=5)

        scrollbar = ttk.Scrollbar(queue_frame, orient="vertical", command=self.queue_tree.yview)
        scrollbar.pack(side='right', fill='y')
        self.queue_tree.configure(yscrollcommand=scrollbar.set)

        # Mock data for demonstration
        self.queue_tree.insert("", tk.END, values=("student1", "Download File", "homework.pdf", "Pending"))
        self.queue_tree.insert("", tk.END, values=("student2", "App Access", "discord", "Pending"))

        action_frame = ttk.Frame(self.tab_queue)
        action_frame.pack(fill='x', padx=10, pady=5)
        
        ttk.Button(action_frame, text="Approve Selected", command=self._approve_request).pack(side='left', padx=5)
        ttk.Button(action_frame, text="Deny Selected", command=self._deny_request).pack(side='left', padx=5)
        ttk.Button(action_frame, text="Refresh Queue", command=self._refresh_queue).pack(side='right', padx=5)

    def _build_auto_tab(self):
        limits_frame = ttk.LabelFrame(self.tab_auto, text="Screen Time & Session Limits")
        limits_frame.pack(fill='x', padx=10, pady=10)

        ttk.Label(limits_frame, text="Daily Screen Time Limit (Hours):").pack(side='left', padx=10, pady=10)
        self.time_limit_var = tk.StringVar(value="2.0")
        time_spinbox = ttk.Spinbox(limits_frame, from_=0.5, to=24.0, increment=0.5, textvariable=self.time_limit_var, width=5)
        time_spinbox.pack(side='left', padx=5)

        ttk.Button(limits_frame, text="Set Limit", command=self._set_time_limit).pack(side='left', padx=20)

        schedule_frame = ttk.LabelFrame(self.tab_auto, text="Curfew & Bedtime Enforcement")
        schedule_frame.pack(fill='x', padx=10, pady=10)

        ttk.Label(schedule_frame, text="System Lockout Time:").grid(row=0, column=0, padx=10, pady=10, sticky='w')
        self.curfew_time_var = tk.StringVar(value="21:00")
        ttk.Entry(schedule_frame, textvariable=self.curfew_time_var, width=10).grid(row=0, column=1, padx=5)
        ttk.Label(schedule_frame, text="(HH:MM, 24-hour format)").grid(row=0, column=2, padx=5, sticky='w')

        ttk.Label(schedule_frame, text="System Unlock Time:").grid(row=1, column=0, padx=10, pady=10, sticky='w')
        self.unlock_time_var = tk.StringVar(value="07:00")
        ttk.Entry(schedule_frame, textvariable=self.unlock_time_var, width=10).grid(row=1, column=1, padx=5)

        ttk.Button(schedule_frame, text="Save Schedule", command=self._save_schedule).grid(row=2, column=0, columnspan=3, pady=10)

    # --- Placeholder Backend Functions ---
    def _add_acl_entry(self, list_type):
        target = self.acl_entry.get().strip()
        if not target:
            messagebox.showwarning("Input Error", "Please enter a URL or IP address.")
            return
        logging.info(f"BACKEND CALL: Adding '{target}' to {list_type}.")
        self.acl_listbox.insert(tk.END, f"[{list_type.upper()}] {target}")
        self.acl_entry.delete(0, tk.END)

    def _remove_acl_entry(self):
        selected = self.acl_listbox.curselection()
        for index in reversed(selected):
            logging.info(f"BACKEND CALL: Removing '{self.acl_listbox.get(index)}' from ACL.")
            self.acl_listbox.delete(index)

    def _block_port(self):
        port = self.port_entry.get().strip()
        protocol = self.protocol_var.get()
        if not port.isdigit():
            messagebox.showwarning("Input Error", "Port must be a valid number.")
            return
        logging.info(f"BACKEND CALL: Blocking port {port}/{protocol}.")
        self.network_listbox.insert(tk.END, f"Blocked: Port {port} ({protocol})")
        self.port_entry.delete(0, tk.END)

    def _remove_port_rule(self):
        selected = self.network_listbox.curselection()
        for index in reversed(selected):
            logging.info(f"BACKEND CALL: Removing network rule '{self.network_listbox.get(index)}'.")
            self.network_listbox.delete(index)

    def _browse_directory(self):
        folder = filedialog.askdirectory()
        if folder:
            self.dir_entry.delete(0, tk.END)
            self.dir_entry.insert(0, folder)

    def _apply_rwx(self):
        target_dir = self.dir_entry.get().strip()
        if not target_dir:
            messagebox.showwarning("Input Error", "Please specify a target path.")
            return
        perms = f"{'R' if self.read_var.get() else '-'}{'W' if self.write_var.get() else '-'}{'X' if self.exec_var.get() else '-'}"
        logging.info(f"BACKEND CALL: Setting {perms} on '{target_dir}'.")
        self.rwx_listbox.insert(tk.END, f"[{perms}] {target_dir}")
        self.dir_entry.delete(0, tk.END)

    def _remove_rwx_rule(self):
        selected = self.rwx_listbox.curselection()
        for index in reversed(selected):
            logging.info(f"BACKEND CALL: Removing RWX rule '{self.rwx_listbox.get(index)}'.")
            self.rwx_listbox.delete(index)

    def _apply_app_rule(self):
        app_name = self.app_combo.get().strip()
        status = self.app_status_var.get()
        if not app_name:
            messagebox.showwarning("Input Error", "Please select or enter an application name.")
            return
        logging.info(f"BACKEND CALL: Setting app '{app_name}' to {status}.")
        self.app_listbox.insert(tk.END, f"[{status.upper()}] {app_name}")
        self.app_combo.set('')

    def _remove_app_rule(self):
        selected = self.app_listbox.curselection()
        for index in reversed(selected):
            logging.info(f"BACKEND CALL: Removing app rule '{self.app_listbox.get(index)}'.")
            self.app_listbox.delete(index)

    def _approve_request(self):
        selected = self.queue_tree.selection()
        for item in selected:
            values = self.queue_tree.item(item, 'values')
            logging.info(f"BACKEND CALL: Approved {values[1]} for {values[0]} ({values[2]})")
            self.queue_tree.set(item, column="status", value="Approved")

    def _deny_request(self):
        selected = self.queue_tree.selection()
        for item in selected:
            values = self.queue_tree.item(item, 'values')
            logging.info(f"BACKEND CALL: Denied {values[1]} for {values[0]} ({values[2]})")
            self.queue_tree.set(item, column="status", value="Denied")

    def _refresh_queue(self):
        logging.info("BACKEND CALL: Refreshing request queue.")
        messagebox.showinfo("Refresh", "Queue refreshed from backend.")

    def _set_time_limit(self):
        limit = self.time_limit_var.get()
        logging.info(f"BACKEND CALL: Setting global screen time limit to {limit} hours.")
        messagebox.showinfo("Limit Applied", f"Daily time limit set to {limit} hours.")

    def _save_schedule(self):
        lock = self.curfew_time_var.get()
        unlock = self.unlock_time_var.get()
        logging.info(f"BACKEND CALL: System scheduled to lock at {lock} and unlock at {unlock}.")
        messagebox.showinfo("Schedule Saved", f"Curfew enforced from {lock} to {unlock}.")

    def _show_about(self):
        messagebox.showinfo("About", "ParentControl Admin Interface\nGUI built for Linux Mint.")

    def _show_help(self):
        messagebox.showinfo("Help", "Use the tabs to navigate settings.\nChanges will be applied by the backend system.")

    def handle_gui_exception(self, exc_type, exc_value, exc_traceback):
        error_msg = "".join(traceback.format_exception(exc_type, exc_value, exc_traceback))
        logging.error(f"GUI Exception Caught:\n{error_msg}")

if __name__ == "__main__":
    try:
        logging.info("Starting application...")
        root = tk.Tk()
        
        style = ttk.Style()
        if 'clam' in style.theme_names():
            style.theme_use('clam')
            
        app = ParentControlApp(root)
        root.mainloop()
    except Exception as e:
        error_details = traceback.format_exc()
        logging.critical(f"Critical Application Failure:\n{error_details}")
        
        error_root = tk.Tk()
        error_root.withdraw() 
        messagebox.showerror("Startup Crash", f"The application crashed on startup:\n\n{e}\n\nPlease copy this error to the developer.")
        error_root.destroy()
        
        sys.exit(1)