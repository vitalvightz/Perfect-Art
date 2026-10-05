(() => {
  const $ = (s, el = document) => el.querySelector(s);
  const $$ = (s, el = document) => [...el.querySelectorAll(s)];
  const API = window.PA_CONFIG?.apiBase;
  const TZ = "Europe/London";

  // Toast
  const toast = $("#toast"); let tt;
  const say = msg => { toast.textContent = msg; toast.classList.add("show"); clearTimeout(tt); tt = setTimeout(() => toast.classList.remove("show"), 3200); };

  // Mobile menu
  const nav = $("#nav"), menuBtn = $("#menuBtn");
  menuBtn.addEventListener("click", () => {
    const open = nav.classList.toggle("open");
    menuBtn.setAttribute("aria-expanded", open);
    menuBtn.textContent = open ? "Close" : "Menu";
  });
  $$("#menu a").forEach(a => a.addEventListener("click", () => {
    nav.classList.remove("open"); menuBtn.setAttribute("aria-expanded", "false"); menuBtn.textContent = "Menu";
  }));

  // Active section in nav
  const links = $$("#menu a");
  const io = new IntersectionObserver(entries => {
    entries.forEach(e => {
      if (!e.isIntersecting) return;
      links.forEach(l => l.classList.toggle("active", l.getAttribute("href") === "#" + e.target.id));
    });
  }, { rootMargin: "-45% 0px -50% 0px" });
  ["tickets", "formats", "info"].forEach(id => io.observe(document.getElementById(id)));

  // Hide mobile ticket bar while the tickets section is on screen
  const bar = $("#mobileBar");
  new IntersectionObserver(([e]) => bar.classList.toggle("hide", e.isIntersecting), { threshold: 0.15 })
    .observe($("#tickets"));

  // Countdown. Starts on the sample date and switches to the real one once events load.
  const year = new Date().getFullYear();
  let target = new Date(year, 9, 17, 22, 0, 0);
  if (target < new Date()) target = new Date(year + 1, 9, 17, 22, 0, 0);
  const cells = Object.fromEntries($$("#countdown b").map(b => [b.dataset.u, b]));
  const pad = n => String(n).padStart(2, "0");
  const tick = () => {
    let s = Math.max(0, Math.floor((target - Date.now()) / 1000));
    const d = Math.floor(s / 86400); s %= 86400;
    const h = Math.floor(s / 3600); s %= 3600;
    const m = Math.floor(s / 60); s %= 60;
    cells.d.textContent = pad(d); cells.h.textContent = pad(h); cells.m.textContent = pad(m); cells.s.textContent = pad(s);
  };
  tick(); setInterval(tick, 1000);

  // Ticket cards: quantity steppers and Reserve
  const SALE_LABELS = { sold_out: "Sold out", not_started: "Not on sale yet", ended: "Sales ended" };
  const cards = $$(".ticket").map(t => {
    const out = $("output", t), [minus, plus] = $$(".stepper button", t), reserve = $(".reserve", t);
    const card = { el: t, qty: 1, max: 10, ticketTypeId: null, onSale: false };
    card.render = () => { out.textContent = card.qty; minus.disabled = card.qty <= 1; plus.disabled = card.qty >= card.max; };
    $$(".stepper button", t).forEach(b => b.addEventListener("click", () => {
      card.qty = Math.min(card.max, Math.max(1, card.qty + Number(b.dataset.step))); card.render();
    }));
    card.render();
    reserve.addEventListener("click", () => startCheckout(card, reserve));
    return card;
  });

  async function startCheckout(card, button) {
    if (!API || !card.ticketTypeId) { say("Ticket sales open soon."); return; }
    if (!card.onSale) return;
    const label = button.textContent;
    button.dataset.busy = "1";
    button.disabled = true; button.textContent = "Reserving…";
    try {
      const res = await fetch(`${API}/checkout`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ ticket_type_id: card.ticketTypeId, quantity: card.qty }),
      });
      const data = await res.json().catch(() => ({}));
      if (res.ok && typeof data.redirect_url === "string" && data.redirect_url.startsWith("https://")) {
        // Keep the private ticket link in this browser so tickets.html can show the tickets as soon
        // as the buyer returns. The payment provider never sees it; it's also emailed after payment.
        const orderId = String(data.ticket_ref || "").split(".")[0];
        try { if (orderId) localStorage.setItem(`pa-ticket:${orderId}`, data.ticket_ref); } catch { /* storage blocked */ }
        location.assign(data.redirect_url);
        return;
      }
      say(data.message || "Couldn't start checkout. Try again.");
    } catch {
      say("Couldn't reach the ticket service. Check your connection and try again.");
    }
    delete button.dataset.busy;
    button.disabled = false; button.textContent = label;
  }

  // Live event and ticket data
  const dateParts = new Intl.DateTimeFormat("en-GB", { timeZone: TZ, weekday: "short", day: "numeric", month: "short" });
  // "Sat 31 Oct", without the comma some browsers add after the weekday.
  const fmtDate = { format: d => dateParts.formatToParts(d).filter(p => p.type !== "literal").map(p => p.value).join(" ") };
  const fmtTime = new Intl.DateTimeFormat("en-GB", { timeZone: TZ, hour: "2-digit", minute: "2-digit" });
  const money = (pence, currency) =>
    new Intl.NumberFormat("en-GB", { style: "currency", currency: currency.toUpperCase() }).format(pence / 100);

  function showEvent(ev) {
    const doors = new Date(ev.doors_at);
    $("#nextName").textContent = ev.name;
    $("#barName").textContent = ev.name;
    $("#nextMeta").textContent = `${fmtDate.format(doors)} · Doors ${fmtTime.format(doors)} · ${ev.address}`;
    $("#nextKind").textContent = ev.kind === "bar" ? "Bar" : "Club";
    target = doors; tick();

    ev.ticket_types.slice(0, cards.length).forEach((tt, i) => {
      const card = cards[i], el = card.el;
      card.ticketTypeId = tt.id;
      card.max = Math.max(1, Math.min(tt.max_per_order, 20));
      card.qty = Math.min(card.qty, card.max);
      card.onSale = tt.sale_state === "on_sale";
      card.render();
      $(".placeholder-badge", el).hidden = true;
      $("h3", el).textContent = tt.name;
      $(".price", el).textContent = money(tt.price_pence, tt.currency);
      // Always replace the placeholder perks, even with nothing.
      const list = $("ul", el);
      list.replaceChildren(...tt.perks.map(p => Object.assign(document.createElement("li"), { textContent: p })));
      list.hidden = tt.perks.length === 0;
      const reserve = $(".reserve", el);
      if (reserve.dataset.busy) return; // a checkout is starting; leave the button alone
      reserve.disabled = !card.onSale;
      reserve.textContent = card.onSale ? "Reserve" : (SALE_LABELS[tt.sale_state] || "Unavailable");
    });
  }

  // Load the catalogue, and refresh it every minute while the page is visible so a sales window
  // opening (or a ticket selling out) shows without a reload.
  function loadEvents() {
    if (!API) return;
    fetch(`${API}/events`)
      .then(r => (r.ok ? r.json() : null))
      .then(data => { if (data?.events?.length) showEvent(data.events[0]); })
      .catch(() => { /* keep what's on screen */ });
  }
  loadEvents();
  setInterval(() => { if (document.visibilityState === "visible") loadEvents(); }, 60_000);
  document.addEventListener("visibilitychange", () => { if (document.visibilityState === "visible") loadEvents(); });

  // Mailing list
  $("#signup").addEventListener("submit", e => {
    e.preventDefault();
    const input = $("#email"), msg = $("#formMsg");
    if (!input.checkValidity() || !input.value.trim()) {
      msg.textContent = "Enter a valid email address, like name@example.com.";
      input.focus(); return;
    }
    msg.textContent = "You're on the list. We'll email you before tickets go on sale.";
    input.value = "";
  });

  $("#yr").textContent = year;
})();
