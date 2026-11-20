// The promo source's catalogue: fictional titles with generated posters (posters/poster.html draws them).
// Nothing here is a real film; the names of people are made up from the brand's poem.

export const CLASSES = [
  { id: '1', name: '电影' },
  { id: '2', name: '剧集' },
  { id: '3', name: '动漫' },
  { id: '4', name: '纪录片' },
];

// style: which generator in posters/poster.html; pal: palette index inside that style.
const M = (name, en, year, style, pal, extra = {}) => ({ cls: '1', name, en, year, style, pal, eps: 1, ...extra });
const S = (name, en, year, eps, style, pal, extra = {}) => ({ cls: '2', name, en, year, style, pal, eps, ...extra });
const A = (name, en, year, eps, style, pal, extra = {}) => ({ cls: '3', name, en, year, style, pal, eps, ...extra });
const D = (name, en, year, eps, style, pal, extra = {}) => ({ cls: '4', name, en, year, style, pal, eps, ...extra });

const RAW = [
  M('星垂平野', 'STARS OVER THE PLAIN', 2026, 'field', 0, { score: '9.1' }),
  S('星河往事 第二季', 'ONCE UPON A GALAXY · II', 2026, 24, 'orbit', 0, { score: '8.9' }),
  A('纸船远航', 'PAPER BOAT VOYAGE', 2025, 12, 'geo', 0, { score: '8.7' }),
  D('大江流', 'THE GREAT RIVER', 2026, 6, 'lines', 0, { score: '9.3' }),
  M('山海长歌', 'BALLAD OF PEAKS AND TIDES', 2025, 'moon', 0, { score: '8.8' }),
  S('雾港来信', 'LETTERS FROM FOG HARBOR', 2025, 16, 'sea', 1, { score: '8.5' }),
  M('长夜未眠', 'SLEEPLESS', 2024, 'city', 0, { score: '8.2' }),
  A('月面花园', 'GARDEN ON THE MOON', 2026, 13, 'moon', 2, { score: '9.0' }),
  M('一苇', 'A SINGLE REED', 2023, 'ink', 0, { score: '8.6' }),
  D('极夜观测站', 'POLAR NIGHT STATION', 2025, 4, 'orbit', 2, { score: '8.9' }),
  S('迷城奇谈', 'TALES OF THE MAZE CITY', 2024, 30, 'city', 1, { score: '7.9' }),
  M('浮光纪事', 'A CHRONICLE OF LIGHT', 2023, 'geo', 1, { score: '8.0' }),
  A('云上邮差', 'POSTMAN ABOVE THE CLOUDS', 2024, 24, 'field', 1, { score: '8.8' }),
  M('白昼迷踪', 'LOST IN DAYLIGHT', 2024, 'window', 0, { score: '7.8' }),
  S('第七渡口', 'THE SEVENTH FERRY', 2026, 12, 'sea', 0, { score: '8.4' }),
  D('群岛纪事', 'ARCHIPELAGO', 2024, 8, 'sea', 2, { score: '8.7' }),
  M('逆流回声', 'ECHO UPSTREAM', 2026, 'lines', 1, { score: '8.3' }),
  A('星屑列车', 'STARDUST EXPRESS', 2025, 26, 'orbit', 1, { score: '8.6' }),
  S('长安来信', "LETTERS FROM CHANG'AN", 2025, 40, 'ink', 1, { score: '8.1' }),
  D('匠人手记', 'NOTES OF A CRAFTSMAN', 2023, 10, 'type', 0, { score: '9.0' }),
  M('午夜渡轮', 'MIDNIGHT FERRY', 2022, 'window', 1, { score: '7.7' }),
  A('潮汐少年', 'TIDE BOY', 2026, 12, 'sea', 3, { score: '8.2' }),
  S('归途之约', 'THE PROMISE HOME', 2023, 20, 'field', 2, { score: '8.0' }),
  D('候鸟航线', 'FLYWAYS', 2025, 5, 'field', 3, { score: '8.8' }),
  M('孤舟', 'ONE BOAT', 2025, 'type', 1, { score: '8.9' }),
  A('机械萤火', 'MECHANICAL FIREFLIES', 2025, 12, 'city', 2, { score: '8.4' }),
  S('暗涌边境', 'UNDERCURRENT', 2026, 10, 'lines', 2, { score: '8.3' }),
  D('盐田', 'SALT FIELDS', 2022, 3, 'geo', 2, { score: '8.5' }),
  M('风之形', 'THE SHAPE OF WIND', 2026, 'lines', 3, { score: '8.1' }),
  A('山海奇谈', 'TALES OF PEAKS AND TIDES', 2023, 52, 'geo', 3, { score: '7.9' }),
  S('深蓝之下', 'BENEATH THE BLUE', 2024, 8, 'moon', 1, { score: '8.6' }),
  D('一万公里的夜', 'TEN THOUSAND KM OF NIGHT', 2026, 6, 'city', 3, { score: '8.7' }),
  M('归雁', 'WILD GEESE RETURNING', 2021, 'ink', 2, { score: '8.4' }),
  S('灯塔看守人', 'THE LIGHTHOUSE KEEPER', 2022, 12, 'window', 2, { score: '8.2' }),
  A('云端图书馆', 'THE LIBRARY IN THE CLOUDS', 2024, 12, 'type', 2, { score: '8.5' }),
  D('冰川来信', 'LETTERS FROM THE GLACIER', 2023, 4, 'moon', 3, { score: '8.9' }),
];

const PEOPLE = ['沈星垂', '陆平野', '江映', '舟遥', '林渡', '苏万流', '顾月涌', '温归海', '程一苇', '白川'];
const AREAS = ['中国大陆', '中国大陆', '日本', '法国', '中国香港', '冰岛'];
const BLURBS = [
  '一艘旧船，一条望不见头的河。有人顺流而下寻找一封没有寄出的信，也有人逆流而上，只为把一盏灯送回它来的地方。',
  '夜色从平野尽头漫上来的时候，他们才发现，这趟旅程真正的终点，是出发那天的自己。',
  '潮水每天退去两次，带走一些东西，也留下一些东西。岸上的人把它们一件件拾起，拼成了一座城的记忆。',
  '没有人知道那束光来自哪里。但所有见过它的人，都在第二天清晨做了同一个决定。',
];

export const CATALOG = RAW.map((r, i) => ({
  id: i + 1,
  ...r,
  director: PEOPLE[i % PEOPLE.length],
  actors: [PEOPLE[(i + 3) % PEOPLE.length], PEOPLE[(i + 5) % PEOPLE.length], PEOPLE[(i + 8) % PEOPLE.length]],
  area: AREAS[i % AREAS.length],
  blurb: BLURBS[i % BLURBS.length],
}));

export const className = (id) => CLASSES.find((c) => c.id === id).name;
