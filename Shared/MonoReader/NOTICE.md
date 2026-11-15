# MonoReader acknowledgements

MonoReader is HS Reconnect's own read-only reader for a Unity Mono game's managed memory. It is written in
Swift for this project. It contains no HearthSim code and does not use HearthMirror.

The way it walks Mono's runtime structures (root domain → assemblies → image class cache → classes → fields →
static data) and the Hearthstone field paths it reads are ported from these MIT-licensed projects. Their licenses
require this notice.

## UnitySpy — https://github.com/hackf5/unityspy

MIT License

Copyright (c) 2019 brian t

## UnitySpy (Firestone fork) — https://github.com/Zero-to-Heroes/unity-spy-.net4.5

The MIT License (MIT). The fork's LICENSE file names no copyright holder; it is maintained by the
Zero-to-Heroes (Firestone) project.

## License text (applies to both)

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
