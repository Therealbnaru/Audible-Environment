"""Open an exchange exported from Audible Environment on an iPhone."""
import base64
import json
from pathlib import Path
import subprocess
import tempfile
import tkinter as tk
from tkinter import filedialog, messagebox, ttk
from tkinter.scrolledtext import ScrolledText

root = tk.Tk()
root.title("Audible Environment Diagnostics")
root.geometry("920x740")
preview = ttk.Frame(root)
details = ScrolledText(root, wrap="word", state="disabled")
images = []


def open_exchange():
    path = filedialog.askopenfilename(filetypes=[("Gemini exchange", "*.json")])
    if not path:
        return
    try:
        exchange = json.loads(Path(path).read_text())
        thumbnails = []
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "frame.jpg"
            target = Path(directory) / "frame.png"
            for frame in exchange["frames"]:
                source.write_bytes(base64.b64decode(frame, validate=True))
                subprocess.run(
                    ["sips", "-s", "format", "png", "-Z", "205", str(source),
                     "--out", str(target)],
                    check=True, capture_output=True,
                )
                thumbnails.append(tk.PhotoImage(file=str(target)))
        body = f'PROMPT\n{exchange["prompt"]}\n\nRESPONSE\n{exchange["response"]}'
    except (OSError, ValueError, TypeError, KeyError, subprocess.SubprocessError, tk.TclError):
        messagebox.showerror("Unable to open exchange", "Choose a JSON file exported by Audible Environment.")
        return

    for child in preview.winfo_children():
        child.destroy()
    images[:] = thumbnails
    for index, image in enumerate(images, 1):
        ttk.Label(preview, text=f"Sent frame {index}", image=image, compound="top").pack(side="left", padx=5)
    details.configure(state="normal")
    details.delete("1.0", "end")
    details.insert("1.0", body)
    details.configure(state="disabled")


ttk.Button(root, text="Open Gemini Exchange…", command=open_exchange).pack(pady=10)
preview.pack(pady=8)
details.pack(fill="both", expand=True, padx=12, pady=12)
root.mainloop()
