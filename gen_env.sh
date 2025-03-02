#!/bin/bash
set -e

# SYNOPSIS
# Sets up a Python virtual environment, detects dependencies from Python files,
# installs them, and generates a requirements.txt file.
#
# DESCRIPTION
# This script automates the process of setting up a Python development environment.
# It creates a virtual environment if one doesn't exist, activates it, detects
# dependencies from Python files in the project directory, installs those dependencies,
# and generates a requirements.txt file containing the list of installed packages.
#
# NOTES
# Requires Bash (Bourne Again Shell) and Python 3.6 or later.

# ---------------------------------------------
# Step 1: Create virtual environment if missing
# ---------------------------------------------
if [ ! -d ".venv" ]; then
    if [ -f "version" ]; then
        # Read the Python version from the 'version' file
        PYTHON_VERSION=$(cat version)
        echo "Detected Python version from 'version' file: $PYTHON_VERSION"
        
        # Create virtual environment with the specified Python version if available
        if ! command -v "python$PYTHON_VERSION" &> /dev/null; then
            echo "Python $PYTHON_VERSION not found. Please install it."
            exit 1
        fi
        python$PYTHON_VERSION -m venv .venv
        echo "Created virtual environment using Python $PYTHON_VERSION."
    else
        # Default to system Python 3 if no 'version' file is found
        python3 -m venv .venv
        echo "Created new virtual environment using default Python."
    fi
else
    echo "Using existing virtual environment."
fi

# ---------------------------------------------
# Step 2: Detect OS and activate virtual environment
# ---------------------------------------------
if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" ]]; then
    # Windows platform (Git Bash / Cygwin)
    source .venv/Scripts/activate
    echo "Activated Windows virtual environment."
else
    # UNIX-like (Linux / macOS)
    source .venv/bin/activate
    echo "Activated UNIX virtual environment."
fi

# Install requirements for detection script
pip install requests

# ---------------------------------------------
# Step 3: Create the dependency detection script
# ---------------------------------------------
DETECT_SCRIPT="detect_deps.py"

cat > ${DETECT_SCRIPT} << 'EOF'
#!/usr/bin/env python3
"""
Dependency detector that scans Python files for import statements and
determines the corresponding installable packages.
It also uses a complementary packages dictionary so that if a package is detected,
its complementary packages are added. For example, "rembg" maps to ["onnxruntime"].
"""
import ast
import os
import sys
import json
import requests
from pathlib import Path

DETECT_SCRIPT = "detect_deps.py"

# Complementary packages dictionary: if a key package is detected, add its complementary ones.
COMPLEMENTARY_PACKAGES = {
    "rembg": ["onnxruntime"],
}

# Common import name to package name mappings
KNOWN_MAPPINGS = {
    "PIL": "Pillow",
    "sklearn": "scikit-learn",
    "bs4": "beautifulsoup4",
    "yaml": "PyYAML",
    "cv2": "opencv-python",
    "np": "numpy",
    "pd": "pandas",
    "dotenv": "python-dotenv",
    "nx": "networkx",
    "plt": "matplotlib",
    "matplotlib.pyplot": "matplotlib",
    "requests_html": "requests-html",
}

# Standard library modules (comprehensive list)
STDLIB_MODULES = {
    "abc", "aifc", "argparse", "array", "ast", "asyncio", "atexit", "audioop", "base64", 
    "bdb", "binascii", "binhex", "bisect", "builtins", "bz2", "cProfile", "calendar", 
    "cgi", "cgitb", "chunk", "cmath", "cmd", "code", "codecs", "codeop", "collections", 
    "colorsys", "compileall", "concurrent", "configparser", "contextlib", "contextvars", 
    "copy", "copyreg", "crypt", "csv", "ctypes", "curses", "dataclasses", "datetime", 
    "dbm", "decimal", "difflib", "dis", "distutils", "doctest", "email", "encodings", 
    "ensurepip", "enum", "errno", "faulthandler", "fcntl", "filecmp", "fileinput", 
    "fnmatch", "formatter", "fractions", "ftplib", "functools", "gc", "getopt", 
    "getpass", "gettext", "glob", "grp", "gzip", "hashlib", "heapq", "hmac", "html", 
    "http", "idlelib", "imaplib", "imghdr", "imp", "importlib", "inspect", "io", 
    "ipaddress", "itertools", "json", "keyword", "lib2to3", "linecache", "locale", 
    "logging", "lzma", "macpath", "mailbox", "mailcap", "marshal", "math", "mimetypes", 
    "mmap", "modulefinder", "msilib", "msvcrt", "multiprocessing", "netrc", "nis", 
    "nntplib", "numbers", "operator", "optparse", "os", "ossaudiodev", "parser", 
    "pathlib", "pdb", "pickle", "pickletools", "pipes", "pkgutil", "platform", "plistlib", 
    "poplib", "posix", "pprint", "profile", "pstats", "pty", "pwd", "py_compile", 
    "pyclbr", "pydoc", "queue", "quopri", "random", "re", "readline", "reprlib", 
    "resource", "rlcompleter", "runpy", "sched", "secrets", "select", "selectors", 
    "shelve", "shlex", "shutil", "signal", "site", "smtpd", "smtplib", "sndhdr", 
    "socket", "socketserver", "spwd", "sqlite3", "ssl", "stat", "statistics", 
    "string", "stringprep", "struct", "subprocess", "sunau", "symbol", "symtable", 
    "sys", "sysconfig", "syslog", "tabnanny", "tarfile", "telnetlib", "tempfile", 
    "termios", "test", "textwrap", "threading", "time", "timeit", "tkinter", "token", 
    "tokenize", "trace", "traceback", "tracemalloc", "tty", "turtle", "turtledemo", 
    "types", "typing", "unicodedata", "unittest", "urllib", "uu", "uuid", "venv", 
    "warnings", "wave", "weakref", "webbrowser", "winreg", "winsound", "wsgiref", 
    "xdrlib", "xml", "xmlrpc", "zipapp", "zipfile", "zipimport", "zlib"
}

# Dependencies used by this script; no longer excluded from requirements.txt.
SCRIPT_DEPENDENCIES = {
    "requests"
}

def get_local_modules(directory="."):
    """Identify local modules/packages within the project."""
    local_modules = set()
    
    # Find Python files (modules)
    for path in Path(directory).rglob('*.py'):
        if is_project_file(path):
            module_name = path.stem
            if module_name != "__init__":
                local_modules.add(module_name)
    
    # Find directories with __init__.py (packages)
    for path in Path(directory).rglob('__init__.py'):
        if is_project_file(path):
            package_path = path.parent
            package_name = package_path.name
            local_modules.add(package_name)
            
            # Also add parent packages
            current = package_path
            while str(current) != '.':
                parent = current.parent
                if (parent / '__init__.py').exists():
                    local_modules.add(parent.name)
                current = parent

    # Also check for directories that might be namespace packages (no __init__.py)
    for path in Path(directory).glob('*'):
        if path.is_dir() and not path.name.startswith('.') and not path.name.startswith('__'):
            # If contains Python files, it might be a namespace package
            if any(p.suffix == '.py' for p in path.rglob('*')):
                local_modules.add(path.name)
                
    return local_modules

def is_project_file(path):
    """Determine if a file should be analyzed for imports."""
    path_str = str(path)
    if not path_str.endswith('.py'):
        return False
    if any(excluded in path_str for excluded in ['.venv', '.temp_env', '__pycache__']):
        return False
    if path.name.startswith('.'):
        return False
    if path.name == DETECT_SCRIPT:  # Exclude this script
        return False
    return True

def extract_imports(content):
    """Extract imports from Python file content using AST."""
    imports = set()
    try:
        tree = ast.parse(content)
        for node in ast.walk(tree):
            # Handle regular imports
            if isinstance(node, ast.Import):
                for name in node.names:
                    imports.add(name.name.split('.')[0])
            # Handle from ... import ...
            elif isinstance(node, ast.ImportFrom) and node.module:
                if node.level == 0:
                    base_module = node.module.split('.')[0]
                    imports.add(base_module)
    except SyntaxError:
        pass
    return imports

def find_package_name(import_name, local_modules):
    """Convert an import name to a PyPI package name, filtering out local modules."""
    if import_name in STDLIB_MODULES:
        return None
    if import_name in local_modules:
        return None
    if import_name in KNOWN_MAPPINGS:
        return KNOWN_MAPPINGS[import_name]
    try:
        response = requests.get(f"https://pypi.org/pypi/{import_name}/json", timeout=5)
        if response.status_code == 200:
            return import_name
        lower_name = import_name.lower()
        if lower_name != import_name:
            response = requests.get(f"https://pypi.org/pypi/{lower_name}/json", timeout=5)
            if response.status_code == 200:
                return lower_name
        dashed_name = import_name.replace('_', '-')
        if dashed_name != import_name:
            response = requests.get(f"https://pypi.org/pypi/{dashed_name}/json", timeout=5)
            if response.status_code == 200:
                return dashed_name
    except requests.RequestException:
        pass
    if (not import_name.startswith('_') and 
        not any(char in import_name for char in [' ', '/', '\\', '*'])):
        return import_name
    return None

def scan_project_directory(directory=".", local_modules=None):
    """Scan a directory for Python files and extract their imports."""
    all_imports = set()
    for path in Path(directory).rglob('*.py'):
        if is_project_file(path):
            try:
                with open(path, 'r', encoding='utf-8') as f:
                    content = f.read()
                    all_imports.update(extract_imports(content))
            except Exception as e:
                print(f"Error reading {path}: {e}", file=sys.stderr)
    return all_imports

def get_installable_packages():
    """Get a list of installable packages from project imports."""
    local_modules = get_local_modules()
    print(f"Detected local modules/packages: {', '.join(sorted(local_modules))}", file=sys.stderr)
    imports = scan_project_directory(local_modules=local_modules)
    packages = set()
    for import_name in imports:
        package_name = find_package_name(import_name, local_modules)
        if package_name:
            packages.add(package_name)
    return sorted(list(packages))

if __name__ == "__main__":
    packages = set(get_installable_packages())
    for pkg in list(packages):
        if pkg in COMPLEMENTARY_PACKAGES:
            packages.update(COMPLEMENTARY_PACKAGES[pkg])
    if packages:
        for pkg in sorted(packages):
            print(pkg)
    else:
        sys.exit(0)
EOF

chmod +x ${DETECT_SCRIPT}

# ---------------------------------------------
# Step 4: Run the detection script
# ---------------------------------------------
echo "Scanning project for dependencies..."
python3 ${DETECT_SCRIPT} > detected_packages.txt

# ---------------------------------------------
# Step 5: Install detected dependencies and track them
# ---------------------------------------------
echo "Installing detected dependencies..."
pip freeze > initial_packages.txt

if [ -s detected_packages.txt ] && [ "$(cat detected_packages.txt)" != "No external dependencies detected." ]; then
    while IFS= read -r package; do
        if [[ -z "$package" ]]; then
            continue
        fi
        echo "Installing: $package"
        pip install "$package" || echo "Warning: Failed to install $package"
    done < detected_packages.txt
else
    echo "No external dependencies detected."
fi

# ---------------------------------------------
# Step 6: Generate clean requirements.txt
# ---------------------------------------------
echo "Generating requirements.txt..."
if [ -s detected_packages.txt ] && [ "$(cat detected_packages.txt)" != "No external dependencies detected." ]; then
    cat detected_packages.txt > requirements.txt
    echo "Created requirements.txt with the detected dependencies."
else
    echo "No dependencies detected. Creating empty requirements.txt."
    touch requirements.txt
fi

# ---------------------------------------------
# Step 7: Cleanup
# ---------------------------------------------
echo "Cleaning up..."
rm -f ${DETECT_SCRIPT} detected_packages.txt initial_packages.txt

echo "Setup complete."
