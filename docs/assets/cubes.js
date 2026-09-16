/* The cubes drifting behind the page.

   They are not a loop of pictures: each one is a real 3x3 carrying the same
   orientation-matrix model the app uses, so what you are watching is an actual
   scramble being made and then genuinely unwound, move by move.

   Drawn on a canvas rather than in the DOM — a few hundred little quads a frame
   is nothing for a canvas, and would be a lot of elements otherwise. */
(() => {
  "use strict";

  const canvas = document.getElementById("cube-field");
  if (!canvas || !canvas.getContext) return;
  const ctx = canvas.getContext("2d");

  const still = window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  // Same space as the app: x right, y down, z towards you.
  /* BEGIN generated from Design/tokens.json */
  const COLOUR = [
    [243, 243, 243],    // white
    [255, 216, 4],      // yellow
    [253, 27, 21],      // red
    [254, 136, 4],      // orange
    [9, 214, 71],       // green
    [5, 112, 253],      // blue
  ];
  const PLASTIC = [11, 16, 24];   // the black body the stickers sit on
  const STICKER = 0.84;   // how much of a face the sticker covers
  const POSE = { pitch: -0.42, yaw: -0.62 };
  /* END generated */
  const FACES = [
    { n: [0, -1, 0], c: 0 },   // up     white
    { n: [0, 1, 0], c: 1 },    // down   yellow
    { n: [1, 0, 0], c: 2 },    // right  red
    { n: [-1, 0, 0], c: 3 },   // left   orange
    { n: [0, 0, 1], c: 4 },    // front  green
    { n: [0, 0, -1], c: 5 },   // back   blue
  ];

  const mul = (a, b) => a.map((row) =>
    [0, 1, 2].map((j) => row[0] * b[0][j] + row[1] * b[1][j] + row[2] * b[2][j]));
  const apply = (m, v) => [0, 1, 2].map((i) => m[i][0] * v[0] + m[i][1] * v[1] + m[i][2] * v[2]);
  const I = () => [[1, 0, 0], [0, 1, 0], [0, 0, 1]];

  /// A quarter turn, exact in whole numbers so orientations never drift.
  const quarter = (axis, deg) => {
    const s = deg > 0 ? 1 : -1;
    if (axis === 0) return [[1, 0, 0], [0, 0, -s], [0, s, 0]];
    if (axis === 1) return [[0, 0, s], [0, 1, 0], [-s, 0, 0]];
    return [[0, -s, 0], [s, 0, 0], [0, 0, 1]];
  };

  /// A partial turn, for the moment a layer is halfway round.
  const partial = (axis, radians) => {
    const c = Math.cos(radians), s = Math.sin(radians);
    if (axis === 0) return [[1, 0, 0], [0, c, -s], [0, s, c]];
    if (axis === 1) return [[c, 0, s], [0, 1, 0], [-s, 0, c]];
    return [[c, -s, 0], [s, c, 0], [0, 0, 1]];
  };

  const view = mul(partial(0, POSE.pitch), partial(1, POSE.yaw));   // the pose the app uses too

  class Cube {
    constructor() {
      this.cubies = [];
      for (let x = -1; x <= 1; x++) {
        for (let y = -1; y <= 1; y++) {
          for (let z = -1; z <= 1; z++) {
            if (!x && !y && !z) continue;
            this.cubies.push({ home: [x, y, z], m: I() });
          }
        }
      }
      this.queue = [];
      this.done = [];
      this.turning = null;
      this.wait = Math.random() * 2.5;
      this.mode = "idle";
      this.spin = Math.random() * Math.PI * 2;
    }

    plan() {
      if (this.mode === "idle") {
        // Shuffle it up.
        const count = 8 + Math.floor(Math.random() * 6);
        let last = -1;
        for (let i = 0; i < count; i++) {
          let axis = Math.floor(Math.random() * 3);
          while (axis === last) axis = Math.floor(Math.random() * 3);
          last = axis;
          const layer = Math.random() < 0.5 ? -1 : 1;
          this.queue.push({ axis, layer, deg: Math.random() < 0.5 ? 90 : -90, pace: 0.26 });
        }
        this.mode = "scrambling";
      } else if (this.mode === "scrambling") {
        // And put it back, slower, so you can see it being solved.
        this.queue = this.done.slice().reverse()
          .map((t) => ({ axis: t.axis, layer: t.layer, deg: -t.deg, pace: 0.42 }));
        this.done = [];
        this.mode = "solving";
      } else {
        this.done = [];
        this.mode = "idle";
        this.wait = 1.4 + Math.random() * 2.4;
      }
    }

    step(dt) {
      this.spin += dt * 0.12;

      if (this.turning) {
        this.turning.t += dt / this.turning.pace;
        if (this.turning.t >= 1) {
          const { axis, layer, deg } = this.turning;
          const R = quarter(axis, deg);
          for (const c of this.cubies) {
            if (Math.round(apply(c.m, c.home)[axis]) === layer) c.m = mul(R, c.m);
          }
          if (this.mode === "scrambling") this.done.push({ axis, layer, deg });
          this.turning = null;
        }
        return;
      }

      if (this.wait > 0) { this.wait -= dt; return; }
      if (!this.queue.length) { this.plan(); return; }
      this.turning = Object.assign({ t: 0 }, this.queue.shift());
    }

    /// Every outward-facing sticker, as a quad in view space.
    quads() {
      const out = [];
      const live = this.turning
        ? partial(this.turning.axis,
                  (this.turning.deg * Math.PI / 180) * Math.min(1, this.turning.t))
        : null;
      const lookRound = mul(view, partial(1, this.spin));

      for (const c of this.cubies) {
        const moving = live && Math.round(apply(c.m, c.home)[this.turning.axis]) === this.turning.layer;
        const orient = moving ? mul(live, c.m) : c.m;
        const world = mul(lookRound, orient);

        for (const f of FACES) {
          if (f.n[0] * c.home[0] + f.n[1] * c.home[1] + f.n[2] * c.home[2] !== 1) continue;

          const facing = apply(world, f.n);
          if (facing[2] <= 0.05) continue;              // pointing away from us

          // The face's four corners, in the cubie's own frame.
          const axis = f.n[0] ? 0 : f.n[1] ? 1 : 2;
          const [u, v] = [0, 1, 2].filter((i) => i !== axis);
          const corners = [[-1, -1], [1, -1], [1, 1], [-1, 1]].map(([su, sv]) => {
            const p = [0, 0, 0];
            p[axis] = f.n[axis] * 0.5;
            p[u] = su * 0.5 * STICKER;
            p[v] = sv * 0.5 * STICKER;
            return apply(world, [c.home[0] + p[0], c.home[1] + p[1], c.home[2] + p[2]]);
          });

          // The same face at full width: these tile into the cube's black body.
          const plate = [[-1, -1], [1, -1], [1, 1], [-1, 1]].map(([su, sv]) => {
            const p = [0, 0, 0];
            p[axis] = f.n[axis] * 0.5;
            p[u] = su * 0.5;
            p[v] = sv * 0.5;
            return apply(world, [c.home[0] + p[0], c.home[1] + p[1], c.home[2] + p[2]]);
          });

          const depth = corners.reduce((a, p) => a + p[2], 0) / 4;
          out.push({ corners, plate, depth, colour: COLOUR[f.c], shade: 0.6 + 0.4 * facing[2] });
        }
      }
      out.sort((a, b) => a.depth - b.depth);            // painter's algorithm
      return out;
    }
  }

  // Where the cubes sit, as fractions of the viewport, with their size.
  const SPOTS = [
    { x: 0.12, y: 0.20, r: 42, a: 0.62 },
    { x: 0.87, y: 0.31, r: 36, a: 0.55 },
    { x: 0.19, y: 0.68, r: 28, a: 0.42 },
    { x: 0.81, y: 0.78, r: 46, a: 0.52 },
    { x: 0.46, y: 0.95, r: 26, a: 0.28 },
    { x: 0.93, y: 0.56, r: 20, a: 0.32 },
  ];

  const rgb = (c, shade) =>
    `rgb(${Math.round(c[0] * shade)},${Math.round(c[1] * shade)},${Math.round(c[2] * shade)})`;

  let cubes = [], spots = [], width = 0, height = 0, ratio = 1;

  const resize = () => {
    ratio = Math.min(2, window.devicePixelRatio || 1);
    width = canvas.clientWidth;
    height = canvas.clientHeight;
    canvas.width = Math.floor(width * ratio);
    canvas.height = Math.floor(height * ratio);
    ctx.setTransform(ratio, 0, 0, ratio, 0, 0);
    // Fewer, smaller cubes on a narrow screen.
    const many = width < 620 ? 3 : SPOTS.length;
    spots = SPOTS.slice(0, many);
    if (cubes.length !== spots.length) {
      cubes = spots.map(() => new Cube());
    }
  };

  const draw = () => {
    ctx.clearRect(0, 0, width, height);
    for (let i = 0; i < cubes.length; i++) {
      const spot = spots[i];
      const scale = spot.r * (width < 620 ? 0.8 : 1);
      const cx = spot.x * width;
      const cy = spot.y * height;
      // A gentle perspective, so the near face reads as nearer.
      const trace = (points) => {
        ctx.beginPath();
        points.forEach((p, n) => {
          const k = 6 / (6 - p[2]);
          const x = cx + p[0] * scale * k;
          const y = cy + p[1] * scale * k;
          if (n === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y);
        });
        ctx.closePath();
      };

      ctx.globalAlpha = spot.a;
      for (const q of cubes[i].quads()) {
        // The black body first, then the sticker sitting on it. Shading is done
        // by darkening the colour, not by fading it, so the cube keeps its
        // colour whichever way the face is turned.
        const s = q.shade;
        trace(q.plate);
        ctx.fillStyle = rgb(PLASTIC, s);
        ctx.fill();
        trace(q.corners);
        ctx.fillStyle = rgb(q.colour, s);
        ctx.fill();
      }
    }
    ctx.globalAlpha = 1;
  };

  let last = 0;
  const frame = (now) => {
    const dt = Math.min(0.05, (now - last) / 1000 || 0);
    last = now;
    for (const cube of cubes) cube.step(dt);
    draw();
    requestAnimationFrame(frame);
  };

  window.addEventListener("resize", resize);
  resize();

  if (still) {
    // Hold them mid-scramble rather than animating.
    cubes.forEach((cube) => {
      for (let i = 0; i < 9; i++) {
        const axis = Math.floor(Math.random() * 3);
        const R = quarter(axis, Math.random() < 0.5 ? 90 : -90);
        const layer = Math.random() < 0.5 ? -1 : 1;
        for (const c of cube.cubies) {
          if (Math.round(apply(c.m, c.home)[axis]) === layer) c.m = mul(R, c.m);
        }
      }
    });
    draw();
  } else {
    requestAnimationFrame(frame);
  }
})();
