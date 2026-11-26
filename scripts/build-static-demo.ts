// Generates a fully static, no-server preview site (for drag-and-drop hosting) from the same synthetic demo data
// the app's /demo mode uses. It has no login, no database and no forms; nothing can be saved.
import { mkdirSync, writeFileSync, readFileSync } from "node:fs";
import { DEMO_SECTIONS, demoRows } from "../src/lib/demo";
import { ROLES } from "../src/lib/rbac";

const out = "dist-demo";
mkdirSync(out, { recursive: true });
const css = readFileSync("src/app/globals.css", "utf8");
const data = Object.fromEntries(ROLES.map((r) => [r, { sections: DEMO_SECTIONS[r], ...demoRows(r) }]));

const html = `<!doctype html>
<html lang="ar" dir="rtl"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<link rel="preconnect" href="https://fonts.googleapis.com"><link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@500&family=Noto+Kufi+Arabic:wght@700;800&family=Noto+Sans+Arabic:wght@400;500;600&family=Plus+Jakarta+Sans:wght@600;800&display=swap"><title>نظام الأطراف الاصطناعية والتقويم — عرض تجريبي</title>
<style>${css}
main{max-width:56rem;margin:1.5rem auto;padding:0 1rem}section.card{margin-bottom:1rem}ul.roles{list-style:none;padding:0;display:flex;gap:.5rem;flex-wrap:wrap}
button.lang{background:transparent;color:#fff;text-decoration:underline;padding:0;min-height:0}</style></head>
<body><header class="bar"><strong id="title"></strong><button class="lang" id="lang" type="button"></button></header>
<main><p role="status" id="note"></p><div id="app"></div></main>
<script>
const DATA=${JSON.stringify(data)};
const T={ar:{title:"نظام الأطراف الاصطناعية والتقويم",lang:"English",note:"عرض تجريبي ببيانات وهمية للعرض فقط. لا توجد قاعدة بيانات ولا تسجيل دخول، ولا يُحفظ شيء.",pick:"اختر دوراً لاستعراض واجهته",back:"تغيير الدور",
roles:{admin:"مدير النظام",management:"الإدارة",technician:"فني",doctor:"طبيب",patient:"مريض"},
patients:"المرضى",cases:"الحالات",users:"المستخدمون",catalog:"الكتالوج",inventory:"المخزون",finance:"المالية",name:"الاسم",patient:"المريض",stage:"المرحلة",
st:{assessment:"تقييم",production:"إنتاج",fitting:"تركيب"},pn:["مريض تجريبي ١","مريض تجريبي ٢","مريض تجريبي ٣"],
u:"إدارة الحسابات والأدوار تتطلب قاعدة بيانات فعلية.",c:"الكتالوج فارغ؛ تُضاف المنتجات والأسعار يدوياً.",i:"لا مواد؛ تُدخل الإدارة المخزون يدوياً.",f:"العملة والضريبة والقواعد المالية تُدخل يدوياً. لا أرقام في العرض التجريبي."},
en:{title:"Prosthetics & Orthotics ERP",lang:"العربية",note:"Demo with synthetic data for viewing only. No database, no sign-in, nothing is saved.",pick:"Pick a role to preview its screens",back:"Change role",
roles:{admin:"Admin",management:"Management",technician:"Technician",doctor:"Doctor",patient:"Patient"},
patients:"Patients",cases:"Cases",users:"Users",catalog:"Catalog",inventory:"Inventory",finance:"Finance",name:"Name",patient:"Patient",stage:"Stage",
st:{assessment:"Assessment",production:"Production",fitting:"Fitting"},pn:["Demo patient 1","Demo patient 2","Demo patient 3"],
u:"Account and role management needs a real database.",c:"The catalog is empty; products and prices are added manually.",i:"No items; Management enters inventory manually.",f:"Currency, tax and financial rules are entered manually. No figures in the demo."}};
let lang=localStorage.getItem("lang")||"ar", role=location.hash.slice(1);
const esc=s=>String(s).replace(/[&<>"]/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c]));
function render(){const t=T[lang];document.documentElement.lang=lang;document.documentElement.dir=lang==="ar"?"rtl":"ltr";
document.getElementById("title").textContent=t.title;document.getElementById("lang").textContent=t.lang;document.getElementById("note").textContent=t.note;
const app=document.getElementById("app");
if(!DATA[role]){app.innerHTML='<div class="card"><h1>'+esc(t.pick)+'</h1><ul class="roles">'+Object.keys(DATA).map(r=>'<li><a class="btn" href="#'+r+'">'+esc(t.roles[r])+'</a></li>').join("")+'</ul></div>';return}
const d=DATA[role],s=d.sections;let h='<p><a href="#">'+esc(t.back)+'</a> — <strong>'+esc(t.roles[role])+'</strong></p>';
const card=(k,b)=>'<section class="card"><h2>'+esc(t[k])+'</h2>'+b+'</section>';
if(s.includes("users"))h+=card("users","<p>"+esc(t.u)+"</p>");
if(s.includes("patients"))h+=card("patients",'<table><thead><tr><th>ID</th><th>'+esc(t.name)+'</th></tr></thead><tbody>'+d.patients.map(p=>'<tr><td>'+p.id+'</td><td>'+esc(t.pn[+p.id.slice(-1)-1])+'</td></tr>').join("")+'</tbody></table>');
if(s.includes("cases"))h+=card("cases",'<table><thead><tr><th>ID</th><th>'+esc(t.patient)+'</th><th>'+esc(t.stage)+'</th></tr></thead><tbody>'+d.cases.map(c=>'<tr><td>'+c.id+'</td><td>'+c.patient+'</td><td>'+esc(t.st[c.status])+'</td></tr>').join("")+'</tbody></table>');
if(s.includes("catalog"))h+=card("catalog","<p>Össur · Ottobock · PROTEOR</p><p>"+esc(t.c)+"</p>");
if(s.includes("inventory"))h+=card("inventory","<p>"+esc(t.i)+"</p>");
if(s.includes("finance"))h+=card("finance","<p>"+esc(t.f)+"</p>");
app.innerHTML=h}
document.getElementById("lang").onclick=()=>{lang=lang==="ar"?"en":"ar";try{localStorage.setItem("lang",lang)}catch(e){}render()};
addEventListener("hashchange",()=>{role=location.hash.slice(1);render()});render();
</script></body></html>`;
writeFileSync(`${out}/index.html`, html);
console.log("wrote", `${out}/index.html`, html.length, "bytes");
