// Renders the Markdown docs (copied into ./docs/ at build time) as an
// APISIX-docs-style page: sidebar, article, "on this page" table of contents.
const REPO = "https://github.com/surak/semantic-routing-llm-plugin";
const PAGES = [
  { group: "Getting started" },
  { id: "overview", title: "Overview", file: "docs/README.md", src: "README.md" },
  { group: "Plugin" },
  { id: "ai-decision-router", title: "ai-decision-router", file: "docs/ai-decision-router.md", src: "docs/ai-decision-router.md" },
  { id: "ai-decision-router-zh", title: "ai-decision-router（中文）", file: "docs/zh/ai-decision-router.md", src: "docs/zh/ai-decision-router.md" },
  { id: "design", title: "Design notes", file: "docs/design.md", src: "docs/design.md" },
];
// Links between Markdown files become in-site links; other repo paths go to GitHub.
const LINKS = { "README.md": "overview", "docs/ai-decision-router.md": "ai-decision-router",
                "ai-decision-router.md": "ai-decision-router", "docs/design.md": "design", "design.md": "design" };

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

function fixLinks(root) {
  root.querySelectorAll("a[href]").forEach((a) => {
    const href = a.getAttribute("href");
    if (/^(https?:|#|mailto:)/.test(href)) return;
    const [path, hash] = href.split("#");
    const clean = path.replace(/^\.\//, "");
    if (LINKS[clean]) a.href = "#" + LINKS[clean] + (hash ? "/" + hash : "");
    // sibling plugin pages (./ai-proxy.md) live in the APISIX docs
    else if (/^[\w-]+\.md$/.test(clean) && href.startsWith("./"))
      a.href = `https://apisix.apache.org/docs/apisix/plugins/${clean.replace(/\.md$/, "")}/`;
    else a.href = `${REPO}/tree/main/${clean}`;
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
  fixLinks(content);
  content.querySelectorAll("pre code").forEach((el) => hljs.highlightElement(el));

  const toc = ['<div class="title">On this page</div>'];
  content.querySelectorAll("h2, h3").forEach((h) => {
    h.id = slug(h.textContent);
    h.insertAdjacentHTML("beforeend", `<a class="anchor" href="#${page.id}/${h.id}">#</a>`);
    toc.push(`<a class="${h.tagName === "H3" ? "l3" : ""}" href="#${page.id}/${h.id}">${h.textContent.replace(/#$/, "")}</a>`);
  });
  document.getElementById("toc").innerHTML = toc.length > 1 ? toc.join("") : "";
  document.getElementById("edit").href = `${REPO}/edit/main/${page.src}`;
  document.title = `${page.title} | ai-decision-router`;

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
