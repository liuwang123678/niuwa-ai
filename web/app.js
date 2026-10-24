/* ══════════════════════════════════════════════════════════════════
   牛蛙落地页 · 交互

   六件事，没别的：
     1. 滚动出现（错峰）
     2. 青蛙看着你的鼠标
     3. 演示对话自动播放（陪着说话那只手机壳）
     3b. 干活演示自动播放（Windows 窗口壳，带工具痕迹）
     4. 顶栏滚下去之后补一条分隔线

   零依赖，没有构建步骤。整个站就是一个 html + 一个 css + 这个文件。
   ══════════════════════════════════════════════════════════════════ */

(() => {
  'use strict';

  const calm = matchMedia('(prefers-reduced-motion: reduce)').matches;

  /* ── 1. 滚动出现 ────────────────────────────────────────────────
     用 --d 做错峰，别让一整屏的东西同时冒出来——那看着像加载失败后
     集体闪现。间隔取 App 的 M.stagger（40ms），同一组里依次排开。 */

  const reveals = [...document.querySelectorAll('.reveal')];

  if (calm || !('IntersectionObserver' in window)) {
    reveals.forEach(el => el.classList.add('is-in'));
  } else {
    const io = new IntersectionObserver((entries) => {
      entries.forEach(entry => {
        if (!entry.isIntersecting) return;
        entry.target.classList.add('is-in');
        io.unobserve(entry.target);
      });
    }, { rootMargin: '0px 0px -12% 0px', threshold: 0.08 });

    // 同一个父容器里的一批，按出现顺序错峰
    const buckets = new Map();
    reveals.forEach(el => {
      const p = el.parentElement || document.body;
      const n = buckets.get(p) || 0;
      buckets.set(p, n + 1);
      el.style.setProperty('--d', Math.min(n, 6) * 40 + 'ms');
      io.observe(el);
    });
  }

  /* ── 2. 青蛙看着你 ──────────────────────────────────────────────
     瞳孔在 SVG 里是 mask 上挖出来的**洞**（见 index.html 底部），
     所以"转动眼珠"就是把这俩洞挪一挪——透明的地方透出的是页面底色，
     换个角度看就是眼睛在跟着你转。

     出厂造型里瞳孔只占眼睛的 0.44（宁小勿大），为的就是这个安静看人的
     神态；挪动的上限也得收着：眼睛半径 16.5、瞳孔半径 7.2，理论上能挪
     9.3 个单位，但挪满就成"瞪"了，所以卡在 4.2。 */

  const pupils = [document.getElementById('pupil-l'), document.getElementById('pupil-r')];
  const frog = document.querySelector('.hero__art .frog');

  if (frog && pupils.every(Boolean) && matchMedia('(hover: hover)').matches) {
    const MAX = 4.2;
    let raf = 0;
    let tx = 0, ty = 0;   // 目标
    let cx = 0, cy = 0;   // 当前（缓动追目标）

    const step = () => {
      // 滞后的跟随：鼠标一停，眼睛还慢慢跟过去一点，比硬跟更像活物
      cx += (tx - cx) * 0.14;
      cy += (ty - cy) * 0.14;
      const t = `translate(${cx.toFixed(3)} ${cy.toFixed(3)})`;
      for (const p of pupils) p.setAttribute('transform', t);
      raf = (Math.abs(tx - cx) > 0.02 || Math.abs(ty - cy) > 0.02)
        ? requestAnimationFrame(step)
        : 0;
    };

    addEventListener('pointermove', (e) => {
      const r = frog.getBoundingClientRect();
      let dx = (e.clientX - (r.left + r.width / 2)) / (innerWidth * 0.5);
      let dy = (e.clientY - (r.top + r.height / 2)) / (innerHeight * 0.5);

      // 归一化到"最多 1"的圆里，再把 1 映到 MAX
      const m = Math.hypot(dx, dy);
      const k = m > 1 ? 1 / m : 1;
      tx = dx * k * MAX;
      ty = dy * k * MAX;

      if (!raf) raf = requestAnimationFrame(step);
    }, { passive: true });
  }

  /* ── 3. 演示对话 ────────────────────────────────────────────────
     ⚠️ 这是**照着 App 界面重画的一段预设对话**，不是真在跑模型。
     页面上标了「演示」，这段注释也是同一个意思：别哪天看着看着
     以为网站在调 API——它没有后端，也没有 Key。 */

  const SCRIPT = [
    { from: 'me',   text: '在吗' },
    { from: 'frog', text: '在。面试那事有结果了吗' },
    { from: 'me',   text: '过了 但我不太想去' },
    { from: 'frog', text: '那就不去。那家公司加班你不是一直有意见' },
    { trace: '记忆 · 已记下：拿到 offer，倾向不去' },
    { from: 'me',   text: '我怕以后后悔' },
    { from: 'frog', text: '后悔了再说。现在去，你现在就难受。' },
  ];

  const log = document.getElementById('log');
  let gen = 0;

  // 干活演示有自己的一套序号，**不能跟上面那个共用**：
  // 两段演示的开关都是滚动触发的，滚到两节中间时两个 observer 会先后一起响，
  // 共用一个 gen 就成了"后启动的把先启动的掐死在中途"——被掐的那半段
  // 停在半句话上，而且再也不动了。
  let genW = 0;

  const wait = ms => new Promise(r => setTimeout(r, ms));

  function bubble(from, text) {
    const el = document.createElement('div');
    el.className = 'bub bub--' + (from === 'me' ? 'me' : 'frog');
    el.textContent = text;
    return el;
  }

  function trace(text) {
    const el = document.createElement('div');
    el.className = 'bub__trace';
    el.textContent = text;
    return el;
  }

  function typing() {
    const el = document.createElement('div');
    el.className = 'typing';
    el.innerHTML = '<i></i><i></i><i></i>';
    return el;
  }

  // ⚠️ 必须收容器参数。原来这里写死 append 到 log（手机那只壳），
  // 结果第二段演示整整一条都渲染进了第一段的窗口里，#worklog 一直是空的。
  // 两个演示各有各的窗口，这个参数不能省。
  function show(el, box) {
    box.appendChild(el);
    void el.offsetWidth;          // 逼一次重排，否则加了类也没过渡
    el.classList.add('is-in');
  }

  async function play() {
    if (!log) return;
    const me = ++gen;
    log.textContent = '';

    for (const step of SCRIPT) {
      if (gen !== me) return;

      if (step.from === 'frog') {
        // 先冒一阵"正在打字"，再出这句话——直接蹦出来显得是贴图
        const t = typing();
        log.appendChild(t);
        await wait(calm ? 60 : 700);
        if (gen !== me) return;
        t.remove();
      } else if (step.trace) {
        await wait(calm ? 40 : 400);
        if (gen !== me) return;
      }

      show(step.trace ? trace(step.trace) : bubble(step.from, step.text), log);
      await wait(calm ? 60 : (step.from === 'me' ? 780 : 620));
    }
  }

  const replay = document.getElementById('replay');
  if (replay) replay.addEventListener('click', play);

  /* ── 3b. 干活演示 ───────────────────────────────────────────────
     另一只壳、另一段脚本。内容不是编的：v6 的真机验收里就是这条
     （见 app/tool/code_e2e.dart 第 4+5 条）——它真的把脚本写到桌面、
     真的跑出 5050，第一次还因为自己引号没写对失败过一版。

     工具痕迹那两块照 App 的 tool_trace_tile 画：上面一行「标签 + 参数」，
     下面挂输出。跑代码的时候"跑的到底是什么"必须一眼看见。 */

  const WORK = [
    { from: 'me',   text: '写个 python 脚本算 1 到 100 的和，存到桌面，再跑一下' },
    { tool: '写文件', arg: 'C:\\Users\\你\\Desktop\\n1-sum.py' },
    { tool: '跑命令', arg: 'python n1-sum.py', out: '5050' },
    { from: 'frog', text: '5050。脚本在桌面的 n1-sum.py，想改个数直接说。' },
  ];

  const worklog = document.getElementById('worklog');

  function toolTile(name, arg, out) {
    const el = document.createElement('div');
    el.className = 'tool';

    const hd = document.createElement('div');
    hd.className = 'tool__hd';
    const dot = document.createElement('span');
    dot.className = 'tool__dot';
    const n = document.createElement('span');
    n.className = 'tool__name';
    n.textContent = name;
    const a = document.createElement('code');
    a.className = 'tool__arg';
    a.textContent = arg;
    hd.append(dot, n, a);
    el.append(hd);

    if (out) {
      const o = document.createElement('div');
      o.className = 'tool__out';
      o.textContent = out;
      el.append(o);
    }
    return el;
  }

  async function work() {
    if (!worklog) return;
    const me = ++genW;
    worklog.textContent = '';

    for (const step of WORK) {
      // ⚠️ 这里比的必须是 genW。原来比的是 gen（手机那段的计数器），
      // 而 me 是 genW，两边的起点都是 0/1 —— 除非手机那段碰巧先跑过、
      // 把 gen 顶成跟 genW 一样的数，否则 **第一轮就 return**，
      // 整段演示一个字都不出。改计数器时这三个地方要一起改。
      if (genW !== me) return;

      if (step.from === 'frog') {
        const t = typing();
        worklog.appendChild(t);
        await wait(calm ? 60 : 700);
        if (genW !== me) return;
        t.remove();
      }

      // 工具痕迹不是聊天，先顿一下再冒出来，像真在干活
      if (step.tool) await wait(calm ? 40 : 520);

      show(
        step.tool
          ? toolTile(step.tool, step.arg, step.out)
          : bubble(step.from, step.text),
        worklog
      );
      await wait(calm ? 60 : (step.from === 'me' ? 780 : 620));
    }
  }

  // 那段窗口滚到眼前再开演。两个演示各有各的开关,互不干扰。
  const stage2 = document.querySelector('.win-wrap');
  if (stage2 && 'IntersectionObserver' in window) {
    const once2 = new IntersectionObserver((entries) => {
      if (entries.some(e => e.isIntersecting)) {
        once2.disconnect();
        work();
      }
    }, { threshold: 0.3 });
    once2.observe(stage2);
  } else {
    work();
  }

  // 手机滚到眼前再开演——没看见就演完了最亏
  const stage = document.querySelector('.phone-wrap');
  if (stage && 'IntersectionObserver' in window) {
    const once = new IntersectionObserver((entries) => {
      if (entries.some(e => e.isIntersecting)) {
        once.disconnect();
        play();
      }
    }, { threshold: 0.35 });
    once.observe(stage);
  } else {
    play();
  }

  /* ── 4. 顶栏 ────────────────────────────────────────────────────
     在顶上时不画线（跟首屏连成一片），滚下去了才补一条，免得
     内容从顶栏底下穿过去显得糊。 */

  const nav = document.getElementById('nav');
  if (nav) {
    const onScroll = () => nav.classList.toggle('is-stuck', scrollY > 8);
    addEventListener('scroll', onScroll, { passive: true });
    onScroll();
  }
})();
