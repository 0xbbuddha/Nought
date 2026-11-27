const fs=require("fs"),assert=require("assert");
const src=fs.readFileSync(process.argv[2],"utf8");
const fns={};const re=/^    function (\w+)\(([^)]*)\)(?::\s*\w+)?\s*\{\n([\s\S]*?)\n    \}$/gm;let m;
while((m=re.exec(src)))fns[m[1]]={p:m[2].split(",").map(x=>x.split(":")[0].trim()).filter(Boolean),b:m[3]};

// Returns {root, Config}: root carries the extracted functions, Config
// is the plain object they read from and write to, inspectable after a
// call the way the real Config.save() would persist it.
function make(rebindable, overrides){
  const Config={keybindOverrides:overrides,save(){}};
  const root={rebindable};
  const env={Config,root,Object};
  for(const[n,f]of Object.entries(fns)){const k=Object.keys(env);root[n]=new Function(...k,`return function(${f.p}){${f.b}}`)(...k.map(x=>env[x]));}
  // apply() talks to the live compositor and a FileView; setCombo()
  // calls it, so it needs to be a no-op here rather than the real body.
  root.apply=()=>{};
  return {root,Config};
}

const list=[
  {id:"clipboard",label:"Clipboard",mod:"SUPER",key:"V",ipcTarget:"clipboard",ipcAction:"toggle"},
  {id:"bar",label:"Control centre",mod:"SUPER",key:"N",ipcTarget:"bar",ipcAction:"toggle"}
];

let t=make(list,{});
assert.strictEqual(t.root.defaultCombo(list[0]),"SUPER + V");
assert.strictEqual(t.root.comboFor("clipboard"),"SUPER + V","no override falls back to the default");
assert.strictEqual(t.root.entry("nope"),null,"an unknown id is null, not a thrown error");

t=make(list,{clipboard:"SUPER + C"});
assert.strictEqual(t.root.comboFor("clipboard"),"SUPER + C","an override wins over the default");
assert.strictEqual(t.root.comboFor("bar"),"SUPER + N","an override on one entry leaves the other alone");

// Rebinding to the exact default clears the override rather than
// storing a redundant one: Config.keybindOverrides is meant to hold
// only the entries that actually differ.
t=make(list,{clipboard:"SUPER + C"});
t.root.setCombo("clipboard","SUPER + V");
assert.strictEqual(t.Config.keybindOverrides.clipboard,undefined,
  "rebinding back to the default removes the override entry");

t=make(list,{clipboard:"SUPER + C"});
t.root.setCombo("bar","SUPER + ALT + N");
assert.strictEqual(t.Config.keybindOverrides.bar,"SUPER + ALT + N","a real change is stored");
assert.strictEqual(t.Config.keybindOverrides.clipboard,"SUPER + C","an unrelated override is untouched");

console.log("keybinds: combo lookup falls back to the default, setCombo clears a no-op override and stores a real one");
