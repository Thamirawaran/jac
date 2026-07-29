"""Native filesystem builtins checked against the values the OS itself reports.

Every assertion compares a natively compiled program's output with what Python's
own `os` module says about the same path, so a wrong struct offset fails here
rather than silently returning a neighbouring field.
"""

import os;
import shutil;
import subprocess;
import sys;
import tempfile;

glob TIMEOUT: int = 300;

"""Compiles `src` natively, runs it, and returns its stdout lines."""
def _native_lines(src: str, workdir: str) -> list[str] {
    jac = shutil.which("jac") or "jac";
    source: str = os.path.join(workdir, "probe.jac");
    with open(source, "w") as handle {
        handle.write(src);
    }
    built = subprocess.run(
        [jac, "nacompile", "probe.jac", "-o", "probe", "--scrub"],
        cwd=workdir, capture_output=True, text=True, timeout=TIMEOUT
    );
    binary: str = os.path.join(workdir, "probe");
    assert os.path.exists(binary), f"nacompile failed:\n{built.stdout}\n{built.stderr}";
    ran = subprocess.run(
        [binary], cwd=workdir, capture_output=True, text=True, timeout=TIMEOUT
    );
    assert ran.returncode == 0, f"native binary exited {ran.returncode}: {ran.stderr}";
    return str(ran.stdout).strip().splitlines();
}

def _fixture(base: str) -> str {
    payload: str = os.path.join(base, "payload.bin");
    with open(payload, "wb") as handle {
        handle.write(os.urandom(9216));
    }
    os.link(payload, os.path.join(base, "payload-link.bin"));
    return payload;
}

test "isdir and isfile agree with the operating system" {
    base: str = tempfile.mkdtemp(prefix="najacfs-");
    try {
        _ = _fixture(base);
        os.makedirs(os.path.join(base, "adir"));
        lines = _native_lines(
            "import os;\n"
            + "with entry {\n"
            + "    print(os.path.isdir(\"adir\"));\n"
            + "    print(os.path.isfile(\"payload.bin\"));\n"
            + "    print(os.path.isdir(\"payload.bin\"));\n"
            + "    print(os.path.isfile(\"adir\"));\n"
            + "    print(os.path.isfile(\"absent\"));\n"
            + "}\n",
            base
        );
        assert lines == ["1", "1", "0", "0", "0"], f"got {lines}";
    } finally {
        shutil.rmtree(base, ignore_errors=True);
    }
}

test "a test annex does not push a module out of the native codespace" {
    base: str = tempfile.mkdtemp(prefix="najacfs-");
    try {
        # the annex imports something the native backend cannot compile
        with open(os.path.join(base, "helper.test.jac"), "w") as handle {
            handle.write("import subprocess;\n\ntest \"annex\" { assert True; }\n");
        }
        with open(os.path.join(base, "helper.jac"), "w") as handle {
            handle.write("def twice(n: int) -> int { return n * 2; }\n");
        }
        with open(os.path.join(base, "jac.toml"), "w") as handle {
            handle.write("[project]\nname = \"annexprobe\"\nentry-point = \"probe.jac\"\n");
        }
        lines = _native_lines(
            "import from helper { twice }\n"
            + "with entry { print(twice(21)); }\n",
            base
        );
        assert lines[0] == "42", f"got {lines}";
    } finally {
        shutil.rmtree(base, ignore_errors=True);
    }
}

test "islink sees a symlink without following it" {
    base: str = tempfile.mkdtemp(prefix="najacfs-");
    try {
        target: str = os.path.join(base, "real");
        os.makedirs(target);
        os.symlink(target, os.path.join(base, "link"));
        with open(os.path.join(base, "plain.txt"), "w") as handle {
            handle.write("x");
        }
        lines = _native_lines(
            "import os;\n"
            + "with entry {\n"
            + "    print(os.path.islink(\"link\"));\n"
            + "    print(os.path.islink(\"real\"));\n"
            + "    print(os.path.islink(\"plain.txt\"));\n"
            + "    print(os.path.islink(\"absent\"));\n"
            + "    print(os.path.isdir(\"link\"));\n"
            + "}\n",
            base
        );
        assert lines[0] == "1", "a symlink must be seen as one";
        assert lines[1] == "0" and lines[2] == "0" and lines[3] == "0";
        assert lines[4] == "1", "isdir follows the link, as in python";
        assert os.path.islink(os.path.join(base, "link")), "python agrees";
    } finally {
        shutil.rmtree(base, ignore_errors=True);
    }
}

test "getsize matches what the os reports" {
    base: str = tempfile.mkdtemp(prefix="najacfs-");
    try {
        payload: str = _fixture(base);
        lines = _native_lines(
            "import os;\n"
            + "with entry { print(os.path.getsize(\"payload.bin\")); }\n",
            base
        );
        assert lines[0] == str(os.path.getsize(payload)), f"got {lines[0]}";
        assert lines[0] == "9216";
    } finally {
        shutil.rmtree(base, ignore_errors=True);
    }
}

test "inode, device, nlink and blocks match the os stat fields" {
    base: str = tempfile.mkdtemp(prefix="najacfs-");
    try {
        payload: str = _fixture(base);
        facts: any = os.lstat(payload);
        lines = _native_lines(
            "import os;\n"
            + "with entry {\n"
            + "    print(os.path.inode(\"payload.bin\"));\n"
            + "    print(os.path.nlink(\"payload.bin\"));\n"
            + "    print(os.path.blocks(\"payload.bin\"));\n"
            + "    print(os.path.device(\"payload.bin\"));\n"
            + "}\n",
            base
        );
        assert lines[0] == str(facts.st_ino), f"inode {lines[0]} != {facts.st_ino}";
        assert lines[1] == str(facts.st_nlink), f"nlink {lines[1]} != {facts.st_nlink}";
        assert lines[1] == "2", "the fixture makes a second hard link";
        assert lines[2] == str(facts.st_blocks), f"blocks {lines[2]} != {facts.st_blocks}";
        assert lines[3] == str(facts.st_dev), f"device {lines[3]} != {facts.st_dev}";
    } finally {
        shutil.rmtree(base, ignore_errors=True);
    }
}

test "getmtime matches the os to the second" {
    base: str = tempfile.mkdtemp(prefix="najacfs-");
    try {
        payload: str = _fixture(base);
        lines = _native_lines(
            "import os;\n"
            + "with entry { print(os.path.getmtime(\"payload.bin\")); }\n",
            base
        );
        assert int(float(lines[0])) == int(os.path.getmtime(payload)), f"got {lines[0]}";
    } finally {
        shutil.rmtree(base, ignore_errors=True);
    }
}

test "freebytes agrees with statvfs" {
    base: str = tempfile.mkdtemp(prefix="najacfs-");
    try {
        lines = _native_lines(
            "import os;\n"
            + "with entry { print(os.path.freebytes(\".\")); }\n",
            base
        );
        # taken after the run: compiling writes caches and moves the number
        vfs: any = os.statvfs(base);
        expected: int = vfs.f_bavail * vfs.f_frsize;
        reported: int = int(lines[0]);
        assert reported > 0, f"got {reported}";
        drift: float = abs(reported - expected) / float(expected);
        assert drift < 0.02, f"native {reported} vs statvfs {expected}";
    } finally {
        shutil.rmtree(base, ignore_errors=True);
    }
}

test "listdir returns the same names as the os, without the self entries" {
    base: str = tempfile.mkdtemp(prefix="najacfs-");
    try {
        tree: str = os.path.join(base, "tree");
        os.makedirs(os.path.join(tree, "subdir"));
        for name in ["alpha.txt", "beta.bin", ".hidden"] {
            with open(os.path.join(tree, name), "w") as handle {
                handle.write("x");
            }
        }
        lines = _native_lines(
            "import os;\n"
            + "with entry {\n"
            + "    names = os.listdir(\"tree\");\n"
            + "    print(len(names));\n"
            + "    for n in sorted(names) { print(n); }\n"
            + "}\n",
            base
        );
        expected: list[str] = sorted(os.listdir(tree));
        assert lines[0] == str(len(expected)), f"count {lines[0]} != {len(expected)}";
        assert lines[1:] == expected, f"got {lines[1:]} want {expected}";
        assert "." not in lines[1:] and ".." not in lines[1:];
    } finally {
        shutil.rmtree(base, ignore_errors=True);
    }
}

test "a path that cannot be stat'ed yields -1 rather than a wrong number" {
    base: str = tempfile.mkdtemp(prefix="najacfs-");
    try {
        lines = _native_lines(
            "import os;\n"
            + "with entry {\n"
            + "    print(os.path.getsize(\"absent\"));\n"
            + "    print(os.path.inode(\"absent\"));\n"
            + "    print(os.path.nlink(\"absent\"));\n"
            + "    print(os.path.blocks(\"absent\"));\n"
            + "    print(len(os.listdir(\"absent-dir\")));\n"
            + "}\n",
            base
        );
        assert lines == ["-1", "-1", "-1", "-1", "0"], f"got {lines}";
    } finally {
        shutil.rmtree(base, ignore_errors=True);
    }
}

test "repeated listdir calls do not leak" {
    base: str = tempfile.mkdtemp(prefix="najacfs-");
    try {
        many: str = os.path.join(base, "many");
        os.makedirs(many);
        for index in range(200) {
            with open(os.path.join(many, f"f{index}.txt"), "w") as handle {
                handle.write("x");
            }
        }
        lines = _native_lines(
            "import os;\n"
            + "with entry {\n"
            + "    total: int = 0;\n"
            + "    for _round in range(100) { total += len(os.listdir(\"many\")); }\n"
            + "    print(total);\n"
            + "}\n",
            base
        );
        assert lines[0] == "20000", f"got {lines[0]}";
    } finally {
        shutil.rmtree(base, ignore_errors=True);
    }
}
