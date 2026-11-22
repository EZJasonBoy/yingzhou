// Whether one version is newer than another, the way the app's update check decides it
// (client/lib/update/release_info.dart, compareVersions):
//
//   node tools/version-newer.mjs <a> <b>     exit 0 when a is newer than b, 1 when not, 2 when either is not a version
//
// Version numbers follow the digits of a constant (0.4.1421356 is 0.41421356…, 0.4.1468 is 0.41468…): the first two
// numbers are whole numbers, and from the third on each number is the digits of a decimal, so 0.4.1468 is newer
// than 0.4.1421356 and 0.4.14 is the same as 0.4.140. The build number (+11) does not count; a pre-release
// (0.4.0-beta.1) comes before its release.
const pattern = /^v?(\d+(?:\.\d+)*)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$/;

function parse(text) {
  const m = pattern.exec(String(text).trim());
  return m ? { parts: m[1].split('.'), pre: m[2] ?? '' } : null;
}

export function compareVersions(a, b) {
  const x = parse(a), y = parse(b);
  if (!x || !y) return (x ? 1 : 0) - (y ? 1 : 0);
  for (let i = 0; i < Math.max(x.parts.length, y.parts.length); i++) {
    const p = x.parts[i] ?? '0', q = y.parts[i] ?? '0';
    let d;
    if (i < 2) {
      d = Number(p) - Number(q);
    } else {
      const width = Math.max(p.length, q.length);
      const pp = p.padEnd(width, '0'), qq = q.padEnd(width, '0');
      d = pp < qq ? -1 : pp > qq ? 1 : 0;
    }
    if (d !== 0) return Math.sign(d);
  }
  if (x.pre === y.pre) return 0;
  if (!x.pre) return 1;
  if (!y.pre) return -1;
  return x.pre < y.pre ? -1 : 1;
}

// Run as a command (not imported).
if (process.argv[1]?.endsWith('version-newer.mjs')) {
  const [a, b] = process.argv.slice(2);
  if (!parse(a) || !parse(b)) {
    console.error(`not a version: ${!parse(a) ? a : b}`);
    process.exit(2);
  }
  process.exit(compareVersions(a, b) > 0 ? 0 : 1);
}
