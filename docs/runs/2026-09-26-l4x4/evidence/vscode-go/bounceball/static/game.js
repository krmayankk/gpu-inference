(() => {
  "use strict";

  var canvas = document.getElementById("game");
  var ctx = canvas.getContext("2d");
  var scoreEl = document.getElementById("score");
  var highEl = document.getElementById("highscore");
  var livesEl = document.getElementById("lives");
  var msgEl = document.getElementById("msg");
  var finalScoreEl = document.getElementById("finalScore");
  var restartBtn = document.getElementById("restart");

  var W = 0;
  var H = 0;

  var paddle = { w: 130, h: 16, x: 0, y: 0, targetX: 0 };
  var ball = { x: 0, y: 0, r: 10, vx: 0, vy: 0, speed: 6 };
  var trail = [];

  var score = 0;
  var lives = 3;
  var best = 0;
  var state = "ready";
  var lastTime = 0;

  function loadBest() {
    try {
      best = Number(localStorage.getItem("bounceBest") || 0);
    } catch (e) {
      best = 0;
    }
  }
  function saveBest() {
    if (score > best) best = score;
    try {
      localStorage.setItem("bounceBest", best);
    } catch (e) {}
    highEl.textContent = "Best: " + best;
  }

  function resize() {
    var dpr = window.devicePixelRatio || 1;
    W = window.innerWidth;
    H = window.innerHeight;
    canvas.width = Math.round(W * dpr);
    canvas.height = Math.round(H * dpr);
    canvas.style.width = W + "px";
    canvas.style.height = H + "px";
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    paddle.w = Math.min(150, Math.max(90, Math.round(W * 0.12)));
    paddle.h = 16;
    paddle.y = H - 48;
    if (paddle.x === 0) paddle.x = (W - paddle.w) / 2;
    paddle.targetX = Math.max(0, Math.min(W - paddle.w, paddle.targetX));
  }

  function resetBall() {
    ball.x = W / 2;
    ball.y = H / 3;
    var dir = Math.random() < 0.5 ? -1 : 1;
    var a = (Math.random() * 0.5 + 0.2) * (Math.PI / 2);
    ball.speed = 6;
    ball.vx = Math.sin(a) * ball.speed * dir;
    ball.vy = Math.cos(a) * ball.speed;
    trail.length = 0;
  }

  function setLives() {
    var s = "";
    for (var i = 0; i < lives; i++) s += "\u2665";
    for (var j = lives; j < 3; j++) s += "\u2661";
    livesEl.textContent = "Lives: " + s;
  }

  function updateScore() {
    scoreEl.textContent = "Score: " + score;
  }

  function start() {
    score = 0;
    lives = 3;
    setLives();
    updateScore();
    saveBest();
    resetBall();
    state = "playing";
    msgEl.classList.add("hidden");
    lastTime = performance.now();
  }

  function pause() {
    state = "paused";
  }
  function resume() {
    state = "playing";
    lastTime = performance.now();
  }

  function gameOver() {
    state = "over";
    saveBest();
    finalScoreEl.textContent = score;
    msgEl.classList.remove("hidden");
  }

  function onMove(x) {
    if (state !== "playing") return;
    paddle.targetX = x - paddle.w / 2;
  }

  window.addEventListener("mousemove", function (e) { onMove(e.clientX); });
  window.addEventListener("touchmove", function (e) {
    e.preventDefault();
    onMove(e.touches[0].clientX);
  }, { passive: false });
  window.addEventListener("touchstart", function (e) { onMove(e.touches[0].clientX); });
  window.addEventListener("resize", resize);
  restartBtn.addEventListener("click", start);
  canvas.addEventListener("mousedown", function () {
    if (state === "ready") start();
    else if (state === "paused") resume();
  });
  window.addEventListener("keydown", function (e) {
    if (e.key === " " || e.key === "Enter") {
      e.preventDefault();
      if (state === "ready" || state === "over") start();
      else if (state === "paused") resume();
      else pause();
      return;
    }
    if (state !== "playing") return;
    if (e.key === "ArrowLeft") onMove(paddle.x + paddle.w / 2 - 50);
    if (e.key === "ArrowRight") onMove(paddle.x + paddle.w / 2 + 50);
  });

  function step(dt) {
    paddle.x += (paddle.targetX - paddle.x) * 0.35;
    paddle.x = Math.max(0, Math.min(W - paddle.w, paddle.x));

    ball.x += ball.vx * dt;
    ball.y += ball.vy * dt;

    trail.push({ x: ball.x, y: ball.y });
    if (trail.length > 12) trail.shift();

    if (ball.x - ball.r < 0) { ball.x = ball.r; ball.vx = Math.abs(ball.vx); }
    else if (ball.x + ball.r > W) { ball.x = W - ball.r; ball.vx = -Math.abs(ball.vx); }
    if (ball.y - ball.r < 0) { ball.y = ball.r; ball.vy = Math.abs(ball.vy); }

    if (
      ball.vy > 0 &&
      ball.y + ball.r >= paddle.y &&
      ball.y + ball.r <= paddle.y + paddle.h + 12 &&
      ball.x >= paddle.x - ball.r &&
      ball.x <= paddle.x + paddle.w + ball.r
    ) {
      var hit = (ball.x - (paddle.x + paddle.w / 2)) / (paddle.w / 2);
      var ang = hit * (Math.PI / 3);
      ball.speed = Math.min(15, ball.speed + 0.25);
      ball.vx = Math.sin(ang) * ball.speed;
      ball.vy = -Math.cos(ang) * ball.speed;
      ball.y = paddle.y - ball.r;
      score++;
      updateScore();
    }

    if (ball.y - ball.r > H) {
      lives--;
      setLives();
      if (lives <= 0) gameOver();
      else resetBall();
    }
  }

  function roundRect(x, y, w, h, r) {
    ctx.beginPath();
    ctx.moveTo(x + r, y);
    ctx.arcTo(x + w, y, x + w, y + h, r);
    ctx.arcTo(x + w, y + h, x, y + h, r);
    ctx.arcTo(x, y + h, x, y, r);
    ctx.arcTo(x, y, x + w, y, r);
    ctx.closePath();
  }

  function drawPaddle() {
    var g = ctx.createLinearGradient(paddle.x, paddle.y, paddle.x, paddle.y + paddle.h);
    g.addColorStop(0, "#7fe9ff");
    g.addColorStop(1, "#a97bff");
    ctx.fillStyle = g;
    roundRect(paddle.x, paddle.y, paddle.w, paddle.h, 8);
    ctx.fill();
  }

  function drawBall() {
    for (var i = 0; i < trail.length; i++) {
      var t = trail[i];
      var a = (i + 1) / trail.length * 0.35;
      ctx.globalAlpha = a;
      ctx.fillStyle = "#ffd166";
      ctx.beginPath();
      ctx.arc(t.x, t.y, ball.r * (0.4 + 0.6 * (i / trail.length)), 0, Math.PI * 2);
      ctx.fill();
    }
    ctx.globalAlpha = 1;
    var bg = ctx.createRadialGradient(
      ball.x - ball.r / 3, ball.y - ball.r / 3, 1,
      ball.x, ball.y, ball.r
    );
    bg.addColorStop(0, "#ffffff");
    bg.addColorStop(1, "#ffb347");
    ctx.fillStyle = bg;
    ctx.beginPath();
    ctx.arc(ball.x, ball.y, ball.r, 0, Math.PI * 2);
    ctx.fill();
  }

  function drawCenter(text, sub, y) {
    ctx.textAlign = "center";
    ctx.fillStyle = "#e6edf3";
    ctx.font = "700 34px 'Segoe UI', system-ui, sans-serif";
    ctx.fillText(text, W / 2, y);
    if (sub) {
      ctx.fillStyle = "#9fb3c8";
      ctx.font = "400 18px 'Segoe UI', system-ui, sans-serif";
      ctx.fillText(sub, W / 2, y + 34);
    }
  }

  function draw() {
    ctx.clearRect(0, 0, W, H);
    if (state === "ready") {
      drawCenter("Bounce Ball", "Move the mouse to aim the paddle \u2022 keep the ball up!", H * 0.42);
      ctx.textAlign = "center";
      ctx.fillStyle = "#7fe9ff";
      ctx.font = "700 20px 'Segoe UI', system-ui, sans-serif";
      ctx.fillText("Click or press Space to start", W / 2, H * 0.42 + 74);
    } else if (state === "paused") {
      drawCenter("Paused", "Press Space to continue", H * 0.4);
    }
    drawPaddle();
    drawBall();
  }

  function loop(now) {
    requestAnimationFrame(loop);
    var dt = Math.min(2.5, (now - lastTime) / 16.67);
    lastTime = now;
    if (state === "playing") step(dt);
    draw();
  }

  loadBest();
  resize();
  setLives();
  updateScore();
  highEl.textContent = "Best: " + best;
  paddle.targetX = (W - paddle.w) / 2;
  resetBall();
  lastTime = performance.now();
  requestAnimationFrame(loop);
})();
