# Notice

Tatami is an independent project, not a fork. Its design draws on prior work:

- The virtual workspace-switching concept is inspired by [FlashSpace] by
  Wojciech Kulik (GPL-3.0). Tatami reimplements comparable behavior on its own
  stack rather than copying FlashSpace source code.
- The window-tiling model and its BSP operations (warp, balance, rotate,
  mirror, fence-based resize) are adapted from [yabai] by koekeishiya, which
  is MIT-licensed. The relevant copyright notice is reproduced below.

Tatami is licensed under [GPL-3.0](LICENSE). It is not affiliated with,
endorsed by, or otherwise connected to FlashSpace, yabai, or their authors.

## yabai (MIT License)

```
MIT License

Copyright (c) 2019 Åsmund Vikane

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

[FlashSpace]: https://github.com/wojciech-kulik/FlashSpace
[yabai]: https://github.com/koekeishiya/yabai
