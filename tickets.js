(() => {
  const $ = s => document.querySelector(s);
  const API = window.PA_CONFIG?.apiBase;
  const TZ = "Europe/London";
  // The private link is "tickets.html#<order id>.<secret>". The fragment never reaches any server.
  const ref = decodeURIComponent(location.hash.slice(1));

  const statusEl = $("#status");
  function setStatus(title, detail, busy = false) {
    statusEl.hidden = false;
    statusEl.replaceChildren();
    const strong = document.createElement("strong");
    if (busy) strong.append(Object.assign(document.createElement("span"), { className: "spinner", ariaHidden: "true" }));
    strong.append(title);
    statusEl.append(strong);
    if (detail) statusEl.append(Object.assign(document.createElement("p"), { textContent: detail }));
  }

  const dateParts = new Intl.DateTimeFormat("en-GB", { timeZone: TZ, weekday: "long", day: "numeric", month: "long" });
  const fmtDate = { format: d => dateParts.formatToParts(d).filter(p => p.type !== "literal").map(p => p.value).join(" ") };
  const fmtTime = new Intl.DateTimeFormat("en-GB", { timeZone: TZ, hour: "2-digit", minute: "2-digit" });

  function qrImage(code) {
    const qr = qrcode(0, "M");
    qr.addData(code);
    qr.make();
    const img = document.createElement("img");
    img.src = qr.createDataURL(8, 2);
    img.alt = "Ticket QR code";
    return img;
  }

  function renderTickets(order) {
    const list = $("#tickets");
    list.replaceChildren(...order.tickets.map((t, i) => {
      const card = document.createElement("article");
      card.className = "ticket";
      const head = document.createElement("div");
      head.className = "ticket-head";
      head.append(
        Object.assign(document.createElement("b"), { textContent: order.ticket_name }),
        Object.assign(document.createElement("span"), { className: "label", textContent: `${i + 1} of ${order.tickets.length}` }),
      );
      card.append(head);
      if (t.status === "active" && t.code) {
        const box = document.createElement("div");
        box.className = "qr";
        box.append(qrImage(t.code));
        card.append(box);
      } else {
        const when = t.checked_in_at ? ` at ${fmtTime.format(new Date(t.checked_in_at))}` : "";
        card.append(Object.assign(document.createElement("p"), {
          className: "used",
          textContent: t.status === "used" ? `Checked in${when}.` : "This ticket was cancelled.",
        }));
      }
      return card;
    }));
  }

  function render(order) {
    const ev = order.event, doors = new Date(ev.doors_at);
    $("#summary").hidden = false;
    $("#ticketName").textContent = `${order.quantity} × ${order.ticket_name}`;
    $("#eventName").textContent = ev.name;
    $("#eventMeta").textContent = `${fmtDate.format(doors)} · Doors ${fmtTime.format(doors)} · ${ev.address} · ${ev.min_age}+`;

    switch (order.status) {
      case "paid":
        statusEl.hidden = true;
        renderTickets(order);
        $("#tip").hidden = false;
        return true;
      case "pending":
        setStatus("Confirming your payment…", "This usually takes a few seconds. Keep this page open.", true);
        return false;
      case "refunded":
        setStatus("This order was refunded.", "These tickets can no longer be used.");
        renderTickets(order);
        return true;
      case "review":
        setStatus("We're checking this payment.", `We'll email ${order.email || "you"} shortly. You don't need to pay again.`);
        return true;
      default:
        setStatus("This order wasn't completed.", "You haven't been charged. Go back to the homepage to try again.");
        return true;
    }
  }

  async function load(attempt = 0) {
    try {
      const res = await fetch(`${API}/order`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ ref }),
      });
      const data = await res.json().catch(() => ({}));
      if (!res.ok) {
        setStatus("We couldn't load these tickets.", data.message || "Try again in a moment.");
        return;
      }
      const done = render(data);
      // Payment confirmation usually lands within seconds; keep checking for about two minutes.
      if (!done) {
        if (attempt < 40) setTimeout(() => load(attempt + 1), 3000);
        else setStatus("Still confirming your payment.", "If you were charged, your tickets will appear here. Refresh this page in a few minutes.");
      }
    } catch {
      setStatus("Couldn't reach the ticket service.", "Check your connection and refresh this page.");
    }
  }

  if (!API || !/^[0-9a-f-]{36}\.[A-Za-z0-9_-]{43}$/i.test(ref)) {
    setStatus("This ticket link isn't complete.", "Open the full link from your payment confirmation.");
  } else {
    load();
  }
})();
