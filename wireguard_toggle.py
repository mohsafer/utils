import sys
import subprocess
from PyQt5.QtWidgets import (
    QApplication, QWidget, QPushButton,
    QVBoxLayout, QLabel, QTextEdit
)
from PyQt5.QtCore import Qt, QThread, pyqtSignal
from PyQt5.QtGui import QFont, QTextCursor


# ─── Background thread to run the command and stream output ───────────────────
class CommandThread(QThread):
    output_ready = pyqtSignal(str)   # emitted for each line of output
    finished_ok  = pyqtSignal()      # emitted on success
    finished_err = pyqtSignal(str)   # emitted on failure with error summary

    def __init__(self, command):
        super().__init__()
        self.command = command

    def run(self):
        try:
            process = subprocess.Popen(
                self.command,
                shell=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,   # merge stderr → stdout so we see [#] lines
                text=True
            )
            for line in process.stdout:
                line = line.rstrip("\n")
                if line:
                    self.output_ready.emit(line)
            process.wait()
            if process.returncode == 0:
                self.finished_ok.emit()
            else:
                self.finished_err.emit(f"Exit code {process.returncode}")
        except Exception as e:
            self.finished_err.emit(str(e))


# ─── Main window ──────────────────────────────────────────────────────────────
class WireGuardToggle(QWidget):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("WireGuard Tunnel - awg0")
        self.setMinimumSize(420, 400)

        layout = QVBoxLayout()
        layout.setSpacing(12)
        layout.setContentsMargins(25, 20, 25, 20)

        # ── Title ──────────────────────────────────────────────────────────────
        title = QLabel("WireGuard Tunnel Control")
        title.setAlignment(Qt.AlignCenter)
        font = QFont()
        font.setPointSize(11)
        font.setBold(True)
        title.setFont(font)
        layout.addWidget(title)

        # ── UP button ──────────────────────────────────────────────────────────
        self.btn_up = QPushButton("▲  Tunnel UP")
        self.btn_up.setFixedHeight(45)
        self.btn_up.setStyleSheet(
            "background-color: #27ae60; color: white; font-size: 13px; border-radius: 6px;"
        )
        self.btn_up.clicked.connect(self.tunnel_up)
        layout.addWidget(self.btn_up)

        # ── DOWN button ──────────────────────────────���─────────────────────────
        self.btn_down = QPushButton("▼  Tunnel DOWN")
        self.btn_down.setFixedHeight(45)
        self.btn_down.setStyleSheet(
            "background-color: #e74c3c; color: white; font-size: 13px; border-radius: 6px;"
        )
        self.btn_down.clicked.connect(self.tunnel_down)
        layout.addWidget(self.btn_down)

        # ── Status line ────────────────────────────────────────────────────────
        self.status_label = QLabel("Status: –")
        self.status_label.setAlignment(Qt.AlignCenter)
        self.status_label.setWordWrap(True)
        self.status_label.setFixedHeight(30)
        self.status_label.setStyleSheet(
            "font-size: 12px; color: #888888;"
            "border-top: 1px solid #444444; padding-top: 5px;"
        )
        layout.addWidget(self.status_label)

        # ── Log output box ─────────────────────────────────────────────────────
        self.log_box = QTextEdit()
        self.log_box.setReadOnly(True)
        self.log_box.setFont(QFont("Monospace", 9))
        self.log_box.setStyleSheet(
            "background-color: #1e1e1e; color: #d4d4d4;"
            "border: 1px solid #444444; border-radius: 4px; padding: 6px;"
        )
        self.log_box.setMinimumHeight(200)
        layout.addWidget(self.log_box)

        self.setLayout(layout)
        self._thread = None

    # ── Helpers ────────────────────────────────────────────────────────────────
    def set_status(self, ok, message):
        color = "#27ae60" if ok else "#e74c3c"
        self.status_label.setStyleSheet(
            f"font-size: 12px; color: {color};"
            "border-top: 1px solid #444444; padding-top: 5px;"
        )
        self.status_label.setText(message)

    def append_log(self, line):
        """Append a line to the log box with optional coloring."""
        # Color [#] command lines in cyan, errors in red
        if line.startswith("[#]"):
            colored = f'<span style="color:#4ec9b0;">{line}</span>'
        elif any(w in line.lower() for w in ("error", "failed", "fatal")):
            colored = f'<span style="color:#f44747;">{line}</span>'
        else:
            colored = f'<span style="color:#d4d4d4;">{line}</span>'
        self.log_box.append(colored)
        # Auto-scroll to bottom
        self.log_box.moveCursor(QTextCursor.End)

    def set_buttons_enabled(self, enabled):
        self.btn_up.setEnabled(enabled)
        self.btn_down.setEnabled(enabled)

    def start_command(self, command, label):
        """Clear log, show header, disable buttons, launch thread."""
        self.log_box.clear()
        self.append_log(f"<span style='color:#569cd6;'>$ {label}</span>")
        self.set_status(None, f"⏳ Running {label}…")
        self.status_label.setStyleSheet(
            "font-size: 12px; color: #d4d4d4;"
            "border-top: 1px solid #444444; padding-top: 5px;"
        )
        self.set_buttons_enabled(False)

        self._thread = CommandThread(command)
        self._thread.output_ready.connect(self.append_log)
        self._thread.finished_ok.connect(
            lambda: self._on_done(True, f"✅ {label} completed successfully")
        )
        self._thread.finished_err.connect(
            lambda err: self._on_done(False, f"❌ {label} failed: {err}")
        )
        self._thread.start()

    def _on_done(self, ok, message):
        self.set_status(ok, message)
        self.set_buttons_enabled(True)

    # ── Button actions ─────────────────────────────────────────────────────────
    def tunnel_up(self):
        self.start_command("sudo awg-quick up awg0", "Tunnel UP")

    def tunnel_down(self):
        self.start_command("sudo awg-quick down awg0", "Tunnel DOWN")


# ─── Entry point ──────────────────────────────────────────────────────────────
if __name__ == "__main__":
    app = QApplication(sys.argv)
    window = WireGuardToggle()
    window.show()
    sys.exit(app.exec_())