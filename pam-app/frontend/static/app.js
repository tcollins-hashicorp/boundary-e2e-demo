// PAM portal front-end. Polls the API so auto-expiry shows live during the demo.
let filter = "all";
let selected = null;
let cache = [];

const $ = (id) => document.getElementById(id);
const api = (p, opts) => fetch(p, opts).then((r) => (r.ok ? r.json() : Promise.reject(r)));

function fmt(ts) {
  if (!ts) return "—";
  const d = new Date(ts);
  return d.toLocaleString([], { month: "short", day: "numeric", hour: "2-digit", minute: "2-digit", second: "2-digit" });
}

function remaining(expires) {
  const ms = new Date(expires) - new Date();
  if (ms <= 0) return "0:00";
  const m = Math.floor(ms / 60000), s = Math.floor((ms % 60000) / 1000);
  return `${m}:${String(s).padStart(2, "0")}`;
}

async function refresh() {
  cache = await api("/api/requests");
  render();
  if (selected) renderDrawer(cache.find((r) => r.id === selected));
}

function render() {
  const rows = $("rows");
  const list = filter === "all" ? cache : cache.filter((r) => r.status === filter);
  $("count").textContent = `${list.length} record${list.length === 1 ? "" : "s"}`;
  $("empty").hidden = list.length > 0;
  rows.innerHTML = list.map((r) => `
    <tr data-id="${r.id}">
      <td class="num">${r.id}</td>
      <td>${r.requester}</td>
      <td>${r.target}</td>
      <td>${r.window_minutes}m</td>
      <td><span class="pill ${r.status}">${r.status}</span></td>
      <td>${fmt(r.created_at)}</td>
    </tr>`).join("");
  rows.querySelectorAll("tr").forEach((tr) =>
    tr.onclick = () => openDrawer(tr.dataset.id));
}

async function openDrawer(id) {
  selected = id;
  $("drawer").hidden = false;
  renderDrawer(cache.find((r) => r.id === id));
}

async function renderDrawer(r) {
  if (!r) return;
  $("dTitle").textContent = r.id;
  const timeline = await api(`/api/requests/${r.id}/timeline`);

  let access = "";
  if (r.status === "APPROVED") {
    const cls = (new Date(r.expires_at) - new Date() < 120000) ? "countdown ending" : "countdown";
    access = `<div class="field"><div class="k">Access closes in</div>
      <div class="v ${cls}" data-exp="${r.expires_at}">${remaining(r.expires_at)}</div></div>`;
  }

  let controls = "";
  if (r.status === "PENDING") {
    controls = `<div class="decision">
      <button class="btn-approve" onclick="decide('${r.id}','approve')">Approve</button>
      <button class="btn-deny" onclick="decide('${r.id}','deny')">Deny</button>
    </div>`;
  }

  $("drawerBody").innerHTML = `
    <div class="field"><div class="k">Status</div><div class="v"><span class="pill ${r.status}">${r.status}</span></div></div>
    ${access}
    <div class="field"><div class="k">Requester</div><div class="v">${r.requester}</div></div>
    <div class="field"><div class="k">Target</div><div class="v">${r.target}</div></div>
    <div class="field"><div class="k">Window</div><div class="v">${r.window_minutes} minutes</div></div>
    <div class="field"><div class="k">Justification</div><div class="v">${r.reason || "—"}</div></div>
    <div class="field"><div class="k">Approver</div><div class="v">${r.approver || "—"}</div></div>
    ${controls}
    <div class="tl-title">Audit timeline</div>
    <ul class="tl">${timeline.map((e) => `
      <li>
        <div class="ev">${label(e.action)}</div>
        <div class="meta">${fmt(e.ts)} · ${e.actor}</div>
        ${e.detail ? `<div class="det">${e.detail}</div>` : ""}
      </li>`).join("") || "<li class='meta'>No events yet.</li>"}
    </ul>`;
}

function label(action) {
  return ({
    "request-raised": "Request raised",
    "request-approved": "Approved",
    "request-denied": "Denied",
    "access-granted": "Boundary access granted",
    "access-revoked": "Boundary access revoked",
    "grant-error": "Grant error",
    "revoke-error": "Revoke error",
  })[action] || action;
}

async function decide(id, verb) {
  const approver = $("who").textContent.split("·")[0].trim() + " (approver)";
  try {
    await api(`/api/requests/${id}/${verb}`, {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ approver }),
    });
  } catch (e) {
    const msg = await e.text?.();
    alert("Action failed: " + (msg || e.status));
  }
  refresh();
}

// live countdown tick
setInterval(() => {
  const el = document.querySelector(".countdown[data-exp]");
  if (el) {
    el.textContent = remaining(el.dataset.exp);
    if (new Date(el.dataset.exp) - new Date() < 120000) el.classList.add("ending");
  }
}, 1000);

// nav
document.querySelectorAll(".nav-item").forEach((b) => b.onclick = () => {
  document.querySelectorAll(".nav-item").forEach((x) => x.classList.remove("active"));
  b.classList.add("active");
  filter = b.dataset.filter;
  $("viewTitle").textContent = b.textContent;
  render();
});

// modal
$("newBtn").onclick = () => $("modal").hidden = false;
$("cancelBtn").onclick = () => $("modal").hidden = true;
$("closeDrawer").onclick = () => { $("drawer").hidden = true; selected = null; };
$("submitBtn").onclick = async () => {
  const btn = $("submitBtn");
  btn.disabled = true;
  try {
    await api("/api/requests", {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        requester: $("f_requester").value,
        target: $("f_target").value,
        reason: $("f_reason").value,
        window_minutes: parseInt($("f_window").value, 10),
      }),
    });
    $("f_reason").value = "";
  } catch (e) {
    // Never leave the dialog stuck open on a failed/slow submit.
    alert("Could not raise the request. Check the PAM portal logs (podman logs pam-app).");
  } finally {
    $("modal").hidden = true;
    btn.disabled = false;
    refresh();
  }
};

refresh();
setInterval(refresh, 4000);
