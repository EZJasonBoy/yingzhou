// Renders the promo source's clip (clip/clip.html) and packages it as a long HLS playlist: one 12 s segment listed
// many times, so the player shows a film-length duration without a film-length file.
// Needs the promo source running: node tools/promo/server.mjs
import { execFileSync } from 'node:child_process';
import { mkdirSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const build = process.env.PROMO_BUILD || resolve(here, '../../dist/promo/build');
const media = join(build, 'media');
mkdirSync(media, { recursive: true });

const run = (cmd, args) => execFileSync(cmd, args, { stdio: 'inherit' });
run('node', [join(here, 'render.mjs'), 'clip/clip.html', '--fps', '24', '--crf', '18', '--tag', 'clip', '--workers', '4', '--out', join(media, 'film-src.mp4')]);
run('ffmpeg', ['-y', '-loglevel', 'error', '-i', join(media, 'film-src.mp4'), '-f', 'lavfi', '-i', 'anullsrc=r=48000:cl=stereo', '-shortest',
  '-c:v', 'copy', '-c:a', 'aac', '-b:a', '64k', '-bsf:v', 'h264_mp4toannexb', '-f', 'mpegts', join(media, 'film.ts')]);

const playlist = (segments) => {
  let s = '#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:12\n#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-PLAYLIST-TYPE:VOD\n';
  for (let i = 0; i < segments; i++) s += (i ? '#EXT-X-DISCONTINUITY\n' : '') + '#EXTINF:12.000,\nfilm.ts\n';
  return s + '#EXT-X-ENDLIST\n';
};
writeFileSync(join(media, 'film.m3u8'), playlist(530)); // 1:46:00
writeFileSync(join(media, 'episode.m3u8'), playlist(225)); // 45:00
writeFileSync(join(media, 'live.m3u8'), playlist(530));
console.log('media done');
