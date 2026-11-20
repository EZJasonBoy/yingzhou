# 宣传片与作品集

这里是宣传片《一舟映之》（`dist/promo/yingzhou-promo.mp4`）和作品集（`dist/promo/yingzhou-portfolio.pdf`）的全部源文件。画面由网页逐帧渲染，界面是真实应用的截图，配乐由代码合成；不依赖任何下载的素材，只需要 Node 22+、ffmpeg 和本机的 Chrome 或 Edge。

`dist/` 不进仓库，所以成品和中间文件都要在本机生成。

## 重新生成

```bash
# 1. 宣传用片源：虚构的片名、生成的海报、一段原创短片（纯 JSON 采集站，没有蜘蛛代码）
node tools/promo/server.mjs                 # 一直开着，端口 5199
node tools/promo/make-posters.mjs           # 海报 -> dist/promo/build/posters
node tools/promo/make-media.mjs             # 短片 -> dist/promo/build/media

# 2. 用真实应用截图：另起一个引擎（不碰 9978 和 ~/.tvbox-next），再跑截图测试
java -XX:+UnlockDiagnosticVMOptions -XX:-BytecodeVerificationRemote \
  -cp "engine/server/build/install/tvbox-engine/lib/*" tvbox.engine.server.MainKt \
  --port 19979 --data <临时目录> --subscribe http://127.0.0.1:5199/config.json
cd client && flutter test integration_test/promo_shots_test.dart -d windows \
  --dart-define=SHOT_DIR=<仓库>/dist/promo/build/shots
node tools/promo/make-assets.mjs            # 截图 -> dist/promo/build/img

# 3. 宣传片
node tools/promo/make-audio.mjs             # 配乐 -> dist/promo/build/audio.wav
node tools/promo/render.mjs film/index.html --fps 60 --crf 12 --workers 6 --out dist/promo/build/master.mp4
ffmpeg -i dist/promo/build/master.mp4 -i dist/promo/build/audio.wav -map 0:v -map 1:a \
  -c:v libx264 -preset slow -crf 19 -pix_fmt yuv420p -af loudnorm=I=-16:TP=-1.5:LRA=11 \
  -c:a aac -b:a 192k -shortest -movflags +faststart dist/promo/yingzhou-promo.mp4

# 4. 作品集
node tools/promo/make-portfolio.mjs         # -> dist/promo/yingzhou-portfolio.pdf，单页图片在 build/portfolio-pages

# 5. README 的截图、横幅和品牌页（进仓库）
node tools/promo/make-readme-images.mjs     # -> docs/screenshots/*.jpg、docs/brand/{yingzhou-hero,brand-board}.jpg、social-preview.png
```

换了片源里的视频后要给引擎换一个空的 `--data` 目录，否则播放缓存里还是旧的分片。

## 文件

| 文件 | 内容 |
|---|---|
| `catalog.mjs` | 36 部虚构的片子（片名、分类、海报风格） |
| `posters/poster.html` | 十种生成式海报风格 |
| `clip/clip.html` | 播放器里放的那段日出短片 |
| `server.mjs` | 宣传用片源，也把本目录当静态站点，供渲染用 |
| `film/` | 宣传片：`river.js` 是夜色里的河与船，`film.js` 是时间线，每一帧都只由时间决定 |
| `render.mjs` | 把暴露 `window.__seek(t)` 的页面逐帧录成视频，或取静帧（`--stills 1.5,4`） |
| `make-audio.mjs` | 配乐：80 BPM，一小节 3 秒，镜头切换都落在小节上 |
| `portfolio/` | 作品集的 14 页 |
| `sheet.mjs` | 把静帧拼成四宫格，方便过一遍画面 |

预览宣传片：开着 `server.mjs`，浏览器打开 `http://127.0.0.1:5199/film/index.html`（加 `?t=37.6` 停在某一秒，`?plain=1` 只看背景）。

## 改文案

宣传片的字都在 `film/index.html`，时间点在 `film/film.js` 里各个场景函数的开头；作品集的字在 `portfolio/index.html`。改完重跑第 3、4 步即可，不用重新截图。
