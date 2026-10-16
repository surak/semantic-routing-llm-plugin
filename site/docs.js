// Renders the Markdown docs (copied into ./docs/ at build time) as an
// APISIX-docs-style page: sidebar, article, "on this page" table of contents.
const REPO = "https://github.com/surak/semantic-routing-llm-plugin";
const PAGES = [
  { group: "Getting started" },
  { id: "overview", title: "Overview", file: "docs/README.md", src: "README.md" },
  { group: "Reference" },
  { id: "system-one", title: "system_one algorithm", file: "docs/system-one.md", src: "docs/system-one.md" },
  { id: "system-one-zh", title: "system_one 算法（中文）", file: "docs/zh/system-one.md", src: "docs/zh/system-one.md" },
  { id: "system-one-api", title: "The System One API", file: "docs/system-one-api.md", src: "docs/system-one-api.md" },
  { id: "kubernetes", title: "Kubernetes", file: "docs/kubernetes.md", src: "deploy/kubernetes/README.md" },
  { id: "design", title: "Design notes", file: "docs/design.md", src: "docs/design.md" },
  { group: "Contributing" },
  { id: "upstreaming", title: "Submitting to APISIX", file: "docs/upstreaming.md", src: "docs/upstreaming.md" },
];
// Links between Markdown files become in-site links; other repo paths go to GitHub.
const LINKS = {
  "README.md": "overview",
  "docs/system-one.md": "system-one", "system-one.md": "system-one",
  "docs/system-one-api.md": "system-one-api", "system-one-api.md": "system-one-api",
  "deploy/kubernetes/README.md": "kubernetes",
  "docs/design.md": "design", "design.md": "design",
  "docs/upstreaming.md": "upstreaming", "upstreaming.md": "upstreaming",
};

const slug = (t) => t.toLowerCase().replace(/<[^>]+>/g, "").replace(/[^\w\s-]/g, "").trim().replace(/\s+/g, "-");

function prepare(md) {
  md = md.replace(/^---\n[\s\S]*?\n---\n/, "");             // front matter
  md = md.replace(/^import .*$/gm, "")                          // MDX imports
         .replace(/^<Tabs[\s\S]*?\]\}>\s*$/gm, "")             // Docusaurus tabs
         .replace(/^<\/?Tabs>\s*$/gm, "")
         .replace(/^<\/TabItem>\s*$/gm, "")
         .replace(/^<TabItem value="([^"]+)">\s*$/gm, (_, v) =>
           `**${{ "admin-api": "Admin API", adc: "ADC", aic: "Ingress Controller" }[v] || v}**`);
  return md.replace(/^:::(\w+)\n([\s\S]*?)^:::\s*$/gm,       // Docusaurus admonitions
    (_, kind, body) => `<div class="admonition"><div class="label">${kind}</div>\n\n${body}\n</div>`);
}

// Resolve `rel` against the directory of the page's source file in the repo.
function resolvePath(src, rel) {
  const parts = src.split("/").slice(0, -1);
  for (const seg of rel.split("/")) {
    if (seg === "..") parts.pop();
    else if (seg !== "." && seg !== "") parts.push(seg);
  }
  return parts.join("/");
}

function fixLinks(root, page) {
  root.querySelectorAll("a[href]").forEach((a) => {
    const href = a.getAttribute("href");
    if (/^(https?:|#|mailto:)/.test(href)) return;
    const [path, hash] = href.split("#");
    const full = resolvePath(page.src, path);
    if (LINKS[full]) a.href = "#" + LINKS[full] + (hash ? "/" + hash : "");
    // sibling plugin pages (./ai-proxy.md) of APISIX docs
    else if (/^\.\/[\w-]+\.md$/.test(href) && !LINKS[full])
      a.href = `https://apisix.apache.org/docs/apisix/plugins/${path.slice(2, -3)}/`;
    else a.href = `${REPO}/tree/main/${full}`;
  });
}


async function show(id, anchor) {
  const page = PAGES.find((p) => p.id === id) || PAGES[1];
  document.querySelectorAll(".sidebar a").forEach((a) => a.classList.toggle("active", a.dataset.id === page.id));
  document.querySelector(".sidebar").classList.remove("open");
  const content = document.getElementById("content");
  let md;
  try {
    const r = await fetch(page.file);
    if (!r.ok) throw new Error(r.status);
    md = await r.text();
  } catch (e) {
    content.innerHTML = `<p>Could not load ${page.file}. Read it <a href="${REPO}/blob/main/${page.src}">on GitHub</a>.</p>`;
    return;
  }
  content.innerHTML = marked.parse(prepare(md));
  if (!content.querySelector("h1")) content.insertAdjacentHTML("afterbegin", `<h1>${page.title}</h1>`);
  fixLinks(content, page);
  content.querySelectorAll("table").forEach((t) => {
    const wrap = document.createElement("div");
    wrap.className = "table-scroll";
    t.replaceWith(wrap);
    wrap.appendChild(t);
  });
  content.querySelectorAll("pre code").forEach((el) => hljs.highlightElement(el));

  const toc = ['<div class="title">On this page</div>'];
  content.querySelectorAll("h2, h3").forEach((h) => {
    h.id = slug(h.textContent);
    h.insertAdjacentHTML("beforeend", `<a class="anchor" href="#${page.id}/${h.id}">#</a>`);
    toc.push(`<a class="${h.tagName === "H3" ? "l3" : ""}" href="#${page.id}/${h.id}">${h.textContent.replace(/#$/, "")}</a>`);
  });
  document.getElementById("toc").innerHTML = toc.length > 1 ? toc.join("") : "";
  document.getElementById("edit").href = `${REPO}/edit/main/${page.src}`;
  document.title = `${page.title} | System One routing`;

  const target = anchor && document.getElementById(anchor);
  if (target) target.scrollIntoView();
  else window.scrollTo(0, 0);
}

function route() {
  const [id, anchor] = location.hash.slice(1).split("/");
  show(id || "overview", anchor);
}

document.getElementById("sidebar").innerHTML = PAGES.map((p) =>
  p.group ? `<div class="group">${p.group}</div>` : `<a href="#${p.id}" data-id="${p.id}">${p.title}</a>`).join("");
window.addEventListener("hashchange", route);
route();
