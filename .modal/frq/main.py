#!/usr/bin/env python3
"""The app. Replace this with something that earns its container."""

import os
import platform


def main():
    print(os.environ.get("GREETING", "hello"))
    print(f"python   {platform.python_version()}")
    print(f"host     {platform.node()} ({platform.machine()})")


if __name__ == "__main__":
    main()
