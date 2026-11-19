# Third-party notices

Yingzhou (映舟) is licensed under AGPL-3.0 (see `LICENSE`). It includes code adapted from the projects below.

## TVBoxOS — AGPL-3.0

- `engine/jar-host/java/com/github/catvod/**`: the host API jar spiders link against (Spider, SpiderApi, OkHttp, Proxy, ...).
- `engine/runtime-js/src/main/java/**` and the JS spider bootstrap: TVBox's JS spider host (crypto, html parsing rules, module rules).
- `engine/core/.../play/PlayResolver.kt`, `PlayRules`, `M3u8Cleaner.kt`: the parse chain, `rules` handling and m3u8 ad rules follow TVBoxOS and Box (takagen99, AGPL-3.0), which credit FongMi/TV.

- `engine/core/.../net/ConfigNetwork.kt`: how `hosts`, `doh` and `ads` behave follows TVBoxOS (`OkGoHelper.CustomDns`,
  its DoH list and `ips` bootstrap, the fallback to the system's DNS, `AdBlocker`) and Box (the longer DoH list); the
  `*` in `hosts` names and the top-level `headers` list follow FongMi/TV (GPL-3.0), described from its behaviour.

## Win-box — MIT

`engine/runtime-jar/src/main/java/android/**`, `androidx/**` and `dalvik/**` started from Win-box's Android stubs
(`resources/jvm/stubs-src`). The dex2jar repairs in `engine/runtime-jar/src/main/kotlin/tvbox/engine/jar/ClassRepairs.kt`
follow Win-box's `classFix.ts` and `DexJarRepair.java`.

```
MIT License

Copyright (c) 2026 yagami-hue

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

## Libraries

- dex2jar (`de.femtopedia.dex2jar`) — Apache-2.0
- android-json (`com.vaadin.external.google:android-json`, AOSP's org.json) — Apache-2.0
- AndroidX Collection — Apache-2.0
- ASM — BSD-3-Clause
- OkHttp (with `okhttp-dnsoverhttps`), Gson, Jsoup, Ktor, kotlinx — Apache-2.0 / MIT
- quickjs-kt — Apache-2.0; QuickJS — MIT
- path_provider (Flutter, client) — BSD-3-Clause

## Tools

- The Windows installer is built with [Inno Setup](https://jrsoftware.org/isinfo.php), Copyright (C) 1997-2026 Jordan Russell,
  portions Copyright (C) 2000-2026 Martijn Laan; its Simplified Chinese messages are by Zhenghan Yang (Kira).
