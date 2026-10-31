import sys
from PySide6.QtCore import Qt
from PySide6.QtGui import QColor, QPainter
from PySide6.QtWidgets import QApplication, QWidget

LOG = sys.argv[1]


def log(line):
    with open(LOG, "a") as f:
        f.write(line + "\n")


class Target(QWidget):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("starlight-target")
        self.setMouseTracking(True)
        self.resize(960, 540)
        self.on = False

    def paintEvent(self, _):
        QPainter(self).fillRect(self.rect(), QColor("#00ff00" if self.on else "#ff0000"))

    def mousePressEvent(self, e):
        self.on = not self.on
        log(f"press {e.button().name} {int(e.position().x())} {int(e.position().y())}")
        self.update()

    def mouseMoveEvent(self, e):
        log(f"move {int(e.position().x())} {int(e.position().y())}")

    def keyPressEvent(self, e):
        log(f"key {e.text()!r} {e.key()}")

    def showEvent(self, e):
        log("shown")


app = QApplication(sys.argv)
w = Target()
w.show()
sys.exit(app.exec())
