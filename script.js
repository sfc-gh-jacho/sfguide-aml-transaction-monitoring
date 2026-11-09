(function () {
  "use strict";

  function esc(s) {
    return String(s).replace(/[&<>"']/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c];
    });
  }

  // ── SQL blocks: split sql/aml_transaction_monitoring.sql on "-- [step:<id>]" markers ──
  function splitSteps(sql) {
    var steps = {};
    var parts = sql.split(/^-- \[step:([a-z_-]+)\]\s*$/m);
    for (var i = 1; i < parts.length; i += 2) steps[parts[i]] = parts[i + 1].trim();
    return steps;
  }

  function renderCode(el, code) {
    el.innerHTML =
      '<div class="code-bar"><span class="code-lang">SQL</span>' +
      '<button class="copy-btn" type="button">Copy</button></div>' +
      '<pre class="language-sql"><code class="language-sql"></code></pre>';
    var codeEl = el.querySelector("code");
    codeEl.textContent = code;
    if (window.Prism) Prism.highlightElement(codeEl);
    el.querySelector(".copy-btn").addEventListener("click", function () {
      var btn = this;
      copyText(code).then(function () {
        btn.textContent = "Copied!";
        btn.classList.add("copied");
        setTimeout(function () { btn.textContent = "Copy"; btn.classList.remove("copied"); }, 1800);
      });
    });
  }

  function copyText(text) {
    if (navigator.clipboard && window.isSecureContext) return navigator.clipboard.writeText(text);
    var ta = document.createElement("textarea");
    ta.value = text;
    ta.style.position = "fixed";
    ta.style.opacity = "0";
    document.body.appendChild(ta);
    ta.select();
    document.execCommand("copy");
    document.body.removeChild(ta);
    return Promise.resolve();
  }

  var loadErr = '<div class="code-loading">Could not load content. If you opened this file directly, serve the folder over HTTP (e.g. <code>python3 -m http.server</code>).</div>';

  fetch("sql/aml_transaction_monitoring.sql")
    .then(function (r) { if (!r.ok) throw new Error(r.status); return r.text(); })
    .then(function (sql) {
      var steps = splitSteps(sql);
      document.querySelectorAll(".code-wrap[data-step]").forEach(function (el) {
        var code = steps[el.getAttribute("data-step")];
        if (code) renderCode(el, code);
      });
    })
    .catch(function () {
      document.querySelectorAll(".code-wrap[data-step]").forEach(function (el) { el.innerHTML = loadErr; });
    });

  // ── Result tables from data/sample_results.json ──
  function wrap(head, body) {
    return '<div class="table-scroll"><table class="results-table"><thead><tr>' +
      head.map(function (c) { return "<th>" + esc(c) + "</th>"; }).join("") +
      "</tr></thead><tbody>" + body + "</tbody></table></div>";
  }
  function n(v) { return Number(v).toLocaleString(); }
  function usd(v) { return "$" + Number(v).toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 }); }
  function ruleChip(r) { return '<span class="rule-chip rule-' + r.toLowerCase() + '">' + esc(r) + "</span>"; }
  function score(s) { return '<span class="sev ' + (s >= 70 ? "sev-high" : s >= 50 ? "sev-med" : "sev-low") + '">' + s + "</span>"; }
  function kyc(k) { return '<span class="chg chg-' + (k === "HIGH" ? "delete" : k === "MEDIUM" ? "update" : "insert") + '">' + esc(k) + "</span>"; }
  function dir(d) { return '<span class="chg chg-' + (d === "IN" ? "insert" : "update") + '">' + esc(d) + "</span>"; }
  function isNear(t) { return t.type === "CASH_DEPOSIT" && t.amount >= 9000 && t.amount < 10000; }

  var render = {
    ledger: function (d) {
      var body = d.ledger.map(function (t) {
        return '<tr data-planted="' + (t.txn_id >= 900000 ? "1" : "0") + '"><td class="num">' + esc(t.time) + '</td><td class="col-name">' +
          esc(t.type) + "</td><td>" + dir(t.direction) + '</td><td class="num">' + usd(t.amount) + '</td><td class="col-name">' + esc(t.counterparty) + "</td></tr>";
      }).join("");
      return wrap(["Time", "Type", "Direction", "Amount", "Counterparty"], body) +
        '<button class="reveal-btn" type="button" data-reveal>Reveal the structuring deposits</button>';
    },
    rule: function (d, el) {
      var rule = el.getAttribute("data-rule");
      var rows = d.queue.filter(function (a) { return a.rule === rule; })
                        .sort(function (a, b) { return a.alert_id < b.alert_id ? -1 : 1; });
      return wrap(["Alert", "Score", "Customer", "Start", "Explanation"], rows.map(function (a) {
        return '<tr><td class="col-name">' + esc(a.alert_id) + "</td><td>" + score(a.risk_score) + '</td><td class="col-name">' +
          esc(a.customer) + '</td><td class="num">' + esc(a.date) + '</td><td class="wrap">' + esc(a.explanation) + "</td></tr>";
      }).join(""));
    },
    funnel: function (d) {
      var alerts = d.noise.reduce(function (a, r) { return a + r.alerts; }, 0);
      return '<div class="funnel"><div><div class="big-num">' + n(d.totals.transactions) + '</div><span>Transactions scanned</span></div>' +
        '<div><div class="big-num">4</div><span>Rules</span></div>' +
        '<div><div class="big-num" style="color:#B4232C">' + alerts + "</div><span>Alerts to review</span></div></div>" +
        wrap(["Rule", "Transactions scanned", "Alerts"], d.noise.map(function (r) {
          return "<tr><td>" + ruleChip(r.rule) + '</td><td class="num">' + n(r.scanned) + '</td><td class="num"><strong>' + r.alerts + "</strong></td></tr>";
        }).join(""));
    },
    queue: function (d) {
      return wrap(["Alert", "Rule", "Score", "Customer", "KYC", "Region", "Start", "Explanation"], d.queue.map(function (a) {
        return '<tr><td class="col-name">' + esc(a.alert_id) + "</td><td>" + ruleChip(a.rule) + "</td><td>" + score(a.risk_score) +
          '</td><td class="col-name">' + esc(a.customer) + "</td><td>" + kyc(a.kyc_risk) + '</td><td class="col-name">' + esc(a.region) +
          '</td><td class="num">' + esc(a.date) + '</td><td class="wrap">' + esc(a.explanation) + "</td></tr>";
      }).join(""));
    },
    dynamic: function (d) {
      var rules = Object.keys(d.dynamic.after).sort();
      var t = wrap(["Rule", "Before new activity", "After refresh"], rules.map(function (r) {
        var b = d.dynamic.before[r] || 0, a = d.dynamic.after[r];
        return "<tr" + (a !== b ? ' class="flag"' : "") + "><td>" + ruleChip(r) + '</td><td class="num">' + b +
          '</td><td class="num"><strong>' + a + "</strong>" + (a !== b ? ' <span class="delta-up">+' + (a - b) + "</span>" : "") + "</td></tr>";
      }).join(""));
      var h = wrap(["Refresh", "State", "Action", "Trigger"], d.dynamic.history.map(function (x, i) {
        return '<tr><td class="num">' + (d.dynamic.history.length - i) + "</td><td>" + esc(x.state) + '</td><td class="col-name">' +
          esc(x.action) + '</td><td class="col-name">' + esc(x.trigger) + "</td></tr>";
      }).join(""));
      return t + '<h3 class="table-title">Refresh history</h3>' + h;
    },
    "case": function (d) {
      return wrap(["Time", "Type", "Direction", "Amount", "Counterparty", "Flag"], d["case"].map(function (t) {
        return "<tr" + (t.flag ? ' class="near"' : "") + '><td class="num">' + esc(t.time) + '</td><td class="col-name">' + esc(t.type) +
          "</td><td>" + dir(t.direction) + '</td><td class="num">' + usd(t.amount) + '</td><td class="col-name">' + esc(t.counterparty) +
          "</td><td>" + (t.flag ? '<span class="flag-near">' + esc(t.flag) + "</span>" : "") + "</td></tr>";
      }).join(""));
    },
    access: function (d) {
      var cls = { AML_INVESTIGATOR_EAST: "role-admin", AML_INVESTIGATOR_WEST: "role-support", AML_MANAGER: "role-analyst" };
      return wrap(["Role", "Alerts visible", "Regions"], d.access.map(function (a) {
        return '<tr><td><span class="role-chip ' + (cls[a.role] || "") + '">' + esc(a.role) + '</span></td><td class="num"><strong>' +
          a.alerts + '</strong></td><td class="col-name">' + esc(a.regions) + "</td></tr>";
      }).join(""));
    },
    ai: function (d) {
      var facts = {};
      d.queue.forEach(function (a) { facts[a.alert_id] = a; });
      return d.ai.map(function (x) {
        var f = facts[x.alert_id];
        return '<div class="ai-card"><div class="ai-head"><strong class="col-name">' + esc(x.alert_id) + "</strong>" + ruleChip(x.rule) +
          score(x.risk_score) + "</div><p>" + esc(x.summary) + "</p>" +
          (f ? '<div class="ai-facts">Facts given to the model: ' + esc(f.explanation) + "</div>" : "") + "</div>";
      }).join("");
    }
  };

  fetch("data/sample_results.json")
    .then(function (r) { if (!r.ok) throw new Error(r.status); return r.json(); })
    .then(function (d) {
      document.querySelectorAll(".results[data-results]").forEach(function (el) {
        var fn = render[el.getAttribute("data-results")];
        if (fn) el.innerHTML = fn(d, el);
      });
      document.querySelectorAll("[data-reveal]").forEach(function (b) {
        b.addEventListener("click", function () {
          var rows = b.parentNode.querySelectorAll('tr[data-planted="1"]');
          var on = !b.classList.contains("on");
          rows.forEach(function (r) { r.classList.toggle("planted", on); });
          b.classList.toggle("on", on);
          b.textContent = on ? "Hide" : "Reveal the structuring deposits";
        });
      });
    })
    .catch(function () {
      document.querySelectorAll(".results[data-results]").forEach(function (el) { el.innerHTML = loadErr; });
    });

  // ── Mobile Nav ──
  var btn = document.querySelector(".nav-hamburger");
  var links = document.querySelector(".nav-links");
  btn.addEventListener("click", function () {
    var open = links.classList.toggle("open");
    btn.classList.toggle("open", open);
    btn.setAttribute("aria-expanded", String(open));
  });
  links.querySelectorAll("a").forEach(function (a) {
    a.addEventListener("click", function () {
      links.classList.remove("open");
      btn.classList.remove("open");
      btn.setAttribute("aria-expanded", "false");
    });
  });

  // ── Nav Scroll Shadow ──
  var nav = document.getElementById("navbar");
  window.addEventListener("scroll", function () {
    nav.classList.toggle("scrolled", window.scrollY > 10);
  }, { passive: true });

  // ── Reveal on Scroll ──
  if (!window.matchMedia("(prefers-reduced-motion: reduce)").matches && "IntersectionObserver" in window) {
    var observer = new IntersectionObserver(function (entries) {
      entries.forEach(function (e) {
        if (e.isIntersecting) { e.target.classList.add("visible"); observer.unobserve(e.target); }
      });
    }, { threshold: 0.08, rootMargin: "0px 0px -40px 0px" });
    document.querySelectorAll(".reveal").forEach(function (el) { observer.observe(el); });
  } else {
    document.querySelectorAll(".reveal").forEach(function (el) { el.classList.add("visible"); });
  }
})();
