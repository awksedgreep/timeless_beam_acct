#!/usr/bin/env python3
"""Run a command on a pseudo-terminal, press keys at it, and print what
the terminal would show afterwards.

    scripts/pty_keys.py [--size 120x40] [--wait 8] [--keys 'j,j,\\r,1.5,q'] [--raw] -- \\
        mix timeless_beam_acct.watch app@ohm

It is how `mix timeless_beam_acct.watch` is looked at where there is
nobody to look: a test has no terminal, and the screen is drawn on one.

Keys are separated by commas. A number is a pause of that many seconds,
so a digit is written as it is sent: `\\x32` is 2. `\\r` is enter, `\\x1b`
is escape, `\\x1b[D` is the left arrow, and `\\x03` is control and C.

`--wait` is how long the command is given before the first key. `--raw`
prints what the command wrote, and not the screen it made.
"""
import codecs, fcntl, os, pty, re, select, struct, sys, termios, time


def screen(data, cols, rows):
    """What a terminal of this size shows after being sent `data`."""
    grid = [[" "] * cols for _ in range(rows)]
    x = y = 0
    alternate = False
    csi = re.compile(r"\x1b\[([?0-9;]*)([@-~])")
    i = 0
    while i < len(data):
        ch = data[i]
        if ch == "\x1b":
            found = csi.match(data, i)
            if not found:
                i += 1
                continue
            args, final = found.group(1), found.group(2)
            if final == "H":
                parts = [part for part in args.split(";") if part]
                y = (int(parts[0]) if parts else 1) - 1
                x = (int(parts[1]) if len(parts) > 1 else 1) - 1
            elif final == "J":
                grid = [[" "] * cols for _ in range(rows)]
            elif final in "hl" and args == "?1049":
                alternate = final == "h"
                grid = [[" "] * cols for _ in range(rows)]
                x = y = 0
            i = found.end()
            continue
        if ch == "\r":
            x = 0
        elif ch == "\n":
            y = min(y + 1, rows - 1)
        elif ch >= " ":
            if 0 <= y < rows and 0 <= x < cols:
                grid[y][x] = ch
            x += 1
        i += 1
    lines = ["".join(row).rstrip() for row in grid]
    return alternate, lines


def main():
    args = sys.argv[1:]
    size, wait, keys, raw = (120, 40), 8.0, [], False
    while args and args[0] != "--":
        flag = args.pop(0)
        if flag == "--size":
            cols, rows = args.pop(0).split("x")
            size = (int(cols), int(rows))
        elif flag == "--wait":
            wait = float(args.pop(0))
        elif flag == "--keys":
            keys = args.pop(0).split(",")
        elif flag == "--raw":
            raw = True
        else:
            sys.exit(__doc__)
    command = args[1:]
    if not command:
        sys.exit(__doc__)

    pid, fd = pty.fork()
    if pid == 0:
        os.execvp(command[0], command)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", size[1], size[0], 0, 0))
    out = b""

    def drain(seconds):
        nonlocal out
        end = time.time() + seconds
        while time.time() < end:
            ready, _, _ = select.select([fd], [], [], max(0, end - time.time()))
            if fd in ready:
                try:
                    data = os.read(fd, 65536)
                except OSError:
                    return False
                if not data:
                    return False
                out += data
        return True

    alive = drain(wait)
    for key in keys:
        if not alive:
            break
        try:
            alive = drain(float(key))
            continue
        except ValueError:
            pass
        os.write(fd, codecs.decode(key, "unicode_escape").encode("latin-1"))
        alive = drain(0.3)
    if alive:
        drain(1.0)
    try:
        os.kill(pid, 15)
    except ProcessLookupError:
        pass

    if raw:
        sys.stdout.buffer.write(out)
        return
    alternate, lines = screen(out.decode("utf-8", "replace"), *size)
    print("the alternate screen is " + ("on" if alternate else "off"))
    print("\n".join(lines))


main()
