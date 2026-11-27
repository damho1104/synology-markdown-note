import WebKit
import NoteCore

/// Bundled, offline editor. Untrusted HTML is parsed only inside an inert template,
/// never used as the WebView's document. All executable code belongs to this world.
enum OriginalEditorRuntime {
    static let world = WKContentWorld.world(name: "SynologyNote.OriginalEditor")
    static let page = """
    <!doctype html><html lang="\(NoteLocalization.language)"><head><meta charset="utf-8">
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'none'; connect-src 'none'; img-src attachment: data:; style-src 'unsafe-inline'; font-src data:; frame-src 'none'; media-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'">
    <style>
    :root { color-scheme: light dark; font: 14px -apple-system, sans-serif; }
    * { box-sizing: border-box; }
    body { margin:0; background:Canvas; color:CanvasText; }
    #original-toolbar { position:sticky; top:0; z-index:10; display:flex; flex-wrap:wrap; gap:4px; padding:8px 12px; background:Canvas; border-bottom:1px solid GrayText; }
    #original-toolbar button, #original-toolbar select, #original-toolbar input { font:inherit; height:28px; max-width:130px; }
    #original-toolbar button { min-width:28px; }
    #original-toolbar input[type=color] { width:32px; padding:2px; }
    #original-editor { padding:24px 28px; min-height:calc(100vh - 90px); outline:none; line-height:1.55; overflow-wrap:anywhere; overflow:auto; contain:layout paint; }
    #original-editor table { border-collapse:collapse; } #original-editor td, #original-editor th { border:1px solid GrayText; min-width:60px; padding:5px; }
    #original-editor img { max-width:100%; } #original-editor [data-original-opaque] { display:inline-block; padding:3px 8px; border:1px dashed GrayText; border-radius:4px; color:GrayText; user-select:all; }
    #original-dialog { padding:16px; border:1px solid GrayText; border-radius:8px; }
    #original-dialog label { display:block; margin:8px 0; } #original-dialog input { min-width:220px; }
    </style></head><body><div id="original-toolbar" role="toolbar" aria-label="\(htmlEscape(appText("Original HTML Formatting")))"></div>
    <main id="original-editor" role="textbox" aria-label="\(htmlEscape(appText("Original HTML Body")))" aria-multiline="true"></main>
    <dialog id="original-dialog"><form method="dialog"><label id="original-dialog-label" for="original-dialog-value"></label><input id="original-dialog-value"><p><button value="cancel">\(htmlEscape(appText("Cancel")))</button> <button id="original-dialog-confirm" value="ok">\(htmlEscape(appText("Apply")))</button></p></form></dialog>
    </body></html>
    """

    static let labels: [String: String] = [
        "1. List",
        "Add Column to Left",
        "Add Column to Right",
        "Add Row Above",
        "Add Row Below",
        "Align Center",
        "Align Left",
        "Align Right",
        "Attach",
        "Attach Files or Images",
        "Body",
        "Bold",
        "Bulleted List",
        "Checklist",
        "Clear Formatting",
        "Code",
        "Create Table",
        "Delete Column",
        "Delete Row",
        "Delete Table",
        "Edit Table",
        "Edit Table…",
        "Font",
        "Font Size",
        "Gothic",
        "Heading 1",
        "Heading 2",
        "Heading 3",
        "Highlight Color",
        "Indent",
        "Insert Link",
        "Italic",
        "Justify",
        "Link",
        "Link Address",
        "Myungjo",
        "Numbered List",
        "Original Preserved",
        "Outdent",
        "Paragraph Style",
        "Quote",
        "Redo",
        "Remove Link",
        "Rows x Columns (up to 30 x 20)",
        "Strikethrough",
        "Subscript",
        "Superscript",
        "System",
        "Table",
        "Text Color",
        "To Do",
        "Underline",
        "Undo",
        "• List",
    ].reduce(into: [:]) { $0[$1] = appText($1) }

    static let script = #"""
    (() => {
      if (window.originalEditor) return;
      const text = key => labels[key] ?? key;
      const root=document.getElementById('original-editor'), toolbar=document.getElementById('original-toolbar');
      const token='data-sne-'+Array.from(crypto.getRandomValues(new Uint8Array(16)),x=>x.toString(16).padStart(2,'0')).join('');
      const records=new Map(), scopedStyles=[]; let serial=0, original='', baseline='', revision=0, editable=false, composing=false, selection=null, assets=[], fullDocument=null;
      const allowed=new Set('a abbr address article aside b bdi bdo blockquote br caption center cite code col colgroup dd del details dfn div dl dt em figcaption figure font footer h1 h2 h3 h4 h5 h6 header hgroup hr i img input ins kbd label li main mark nav ol p pre q rp rt ruby s samp section small span strike strong sub summary sup table tbody td tfoot th thead time tr tt u ul var wbr'.split(' '));
      const post=body=>window.webkit?.messageHandlers.originalEditor?.postMessage({revision,...body});
      const remember=()=>{const s=getSelection(); if(s.rangeCount && root.contains(s.anchorNode) && root.contains(s.focusNode)) selection=s.getRangeAt(0).cloneRange();};
      const restore=()=>{root.focus(); const s=getSelection(); if(selection && root.contains(selection.startContainer) && root.contains(selection.endContainer)){s.removeAllRanges();s.addRange(selection);} else if(!s.rangeCount || !root.contains(s.anchorNode)){const r=document.createRange();r.selectNodeContents(root);r.collapse(false);s.removeAllRanges();s.addRange(r);}};
      function attachmentFor(el,src) {
        const values=[el.getAttribute('ref'),el.getAttribute('content_id'),src];
        try { const u=new URL(src,'https://inert.invalid'); for(const k of ['file_id','ref','content_id'])values.push(u.searchParams.get(k)); }catch{}
        return assets.find(a=>values.some(v=>v && [a.reference,a.reference.slice('attachment://'.length),a.remoteID,a.remoteReference].filter(Boolean).includes(v)) || values.slice(0,2).includes(a.name));
      }
      function scopeSelectors(value) {
        const parts=[];let start=0,depth=0,quote='';
        for(let i=0;i<value.length;i++){
          const c=value[i];if(c==='\\'){i++;continue;}
          if(quote){if(c===quote)quote='';continue;}
          if(c==='"'||c==="'"){quote=c;continue;}
          if(c==='('||c==='[')depth++;if(c===')'||c===']')depth--;
          if(c===','&&!depth){parts.push(value.slice(start,i));start=i+1;}
        }
        parts.push(value.slice(start));
        return parts.map(s=>{
          s=s.trim().replace(/(^|[\s>+~])(?:html|body|:root)(?=$|[\s.#[:>+~])/g,'$1#original-editor').replace(/#original-editor\s+#original-editor/g,'#original-editor');
          // The final intersection confines even sibling/combinator selectors.
          const pseudo=s.match(/::[\w-]+(?:\([^)]*\))?$/)?.[0]||'';
          if(pseudo)s=s.slice(0,-pseudo.length);
          return ':is('+s+'):is(#original-editor,#original-editor *)'+pseudo;
        }).join(',');
      }
      function installStyle(css) {
        const sheet=new CSSStyleSheet();try{sheet.replaceSync(css);}catch{return;}
        function rules(list){let out='';for(const rule of list){
          if(rule.type===CSSRule.STYLE_RULE)out+=scopeSelectors(rule.selectorText)+'{'+rule.style.cssText+'}';
          else if(rule.type===CSSRule.MEDIA_RULE)out+='@media '+rule.conditionText+'{'+rules(rule.cssRules)+'}';
          else if(rule.type===CSSRule.SUPPORTS_RULE)out+='@supports '+rule.conditionText+'{'+rules(rule.cssRules)+'}';
        }return out;}
        const style=document.createElement('style');style.textContent=rules(sheet.cssRules);document.head.append(style);scopedStyles.push(style);
      }
      function prepare(node, preserve=true) {
        if(node.nodeType!==1) return;
        const tag=node.localName;
        if(tag==='style' && preserve)installStyle(node.textContent);
        const opaque=!allowed.has(tag) || (tag==='input' && node.type!=='checkbox') || node.hasAttribute('contenteditable') && node.getAttribute('contenteditable')==='false' && tag!=='input';
        const id=String(++serial);
        if(opaque) {
          const placeholder=document.createElement('span');
          placeholder.setAttribute(token,id); placeholder.setAttribute('data-original-opaque',''); placeholder.contentEditable='false';
          placeholder.setAttribute('aria-label',tag+' · '+text('Original Preserved')); placeholder.textContent='▤ '+tag+' · '+text('Original Preserved');
          records.set(id,{opaque: node.outerHTML}); node.replaceWith(placeholder); return;
        }
        const saved={};
        for(const attr of Array.from(node.attributes)) {
          const name=attr.name.toLowerCase();
          if(name.startsWith('on') || ['srcdoc','srcset','autofocus','contenteditable','draggable'].includes(name)) {
            if(preserve)saved[attr.name]=attr.value; node.removeAttribute(attr.name);
          }
        }
        if(tag==='img') {
          const src=node.getAttribute('src');
          const asset=attachmentFor(node,src||'');
          if(asset) { saved.src=src; node.setAttribute('src',asset.reference); }
          else if(src!==null) {
            if(!/^data:image\/(png|jpeg|gif|webp);base64,/i.test(src)) { if(preserve)saved.src=src; node.removeAttribute('src'); }
          }
        }
        if(tag==='a') {
          const href=node.getAttribute('href');
          if(href && /^\s*(javascript|vbscript|data):/i.test(href)){if(preserve)saved.href=href;node.removeAttribute('href');}
        }
        if(Object.keys(saved).length){node.setAttribute(token,id);records.set(id,{attributes:saved});}
        for(const child of Array.from(node.children))prepare(child,preserve);
      }
      function fragment(html, preserve) {
        const t=document.createElement('template'); t.innerHTML=html;
        for(const child of Array.from(t.content.children)) prepare(child,preserve);
        return t.content;
      }
      function exported(container) {
        const copy=container.cloneNode(true);
        for(const el of Array.from(copy.querySelectorAll('['+token+']'))) {
          const record=records.get(el.getAttribute(token));
          if(record?.opaque!==undefined){const t=document.createElement('template');t.innerHTML=record.opaque;el.replaceWith(t.content);continue;}
          if(record?.attributes)for(const [k,v] of Object.entries(record.attributes))v===null?el.removeAttribute(k):el.setAttribute(k,v);
          el.removeAttribute(token);
        }
        return copy.innerHTML;
      }
      function getHTML() {
        if(root.innerHTML===baseline)return original;
        const body=exported(root);
        if(!fullDocument)return body;
        const doc=fullDocument.cloneNode(true);doc.body.innerHTML=body;
        const dt=doc.doctype;const prefix=dt ? '<!DOCTYPE '+dt.name+(dt.publicId?' PUBLIC "'+dt.publicId+'"':'')+(dt.systemId?' "'+dt.systemId+'"':'')+'>' : '';
        return prefix+doc.documentElement.outerHTML;
      }
      let lastEmitted='';
      function changed() {
        if(!editable || composing)return;
        remember();const html=getHTML();if(html===lastEmitted)return;lastEmitted=html;post({html});
      }
      function load(html, attachments, enabled, nextRevision) {
        records.clear();scopedStyles.splice(0).forEach(s=>s.remove());root.removeAttribute('style');root.removeAttribute('class');serial=0;selection=null;composing=false;original=html;lastEmitted=html;assets=attachments;revision=nextRevision;fullDocument=null;
        let body=html;
        if(/^\s*(?:<!doctype|<html\b|<head\b|<body\b)/i.test(html)){fullDocument=new DOMParser().parseFromString(html,'text/html');body=fullDocument.body.innerHTML;root.style.cssText=fullDocument.body.style.cssText;root.className=fullDocument.body.className;for(const style of fullDocument.head.querySelectorAll('style'))installStyle(style.textContent);}
        root.replaceChildren(fragment(body,true));baseline=root.innerHTML;setEditable(enabled);return true;
      }
      function updateAttachments(nextAssets){
        const unchanged=root.innerHTML===baseline;assets=nextAssets;
        for(const image of root.querySelectorAll('img')){
          let id=image.getAttribute(token),record=records.get(id);
          const saved=record?.attributes||{};
          const source=Object.hasOwn(saved,'src')?saved.src:image.getAttribute('src');
          const asset=attachmentFor(image,source||'');
          if(asset){
            if(!Object.hasOwn(saved,'src'))saved.src=source;
            if(!id){id=String(++serial);image.setAttribute(token,id);}
            records.set(id,{attributes:saved});image.setAttribute('src',asset.reference);
          }else if(!/^data:image\/(png|jpeg|gif|webp);base64,/i.test(source||'')){image.removeAttribute('src');}
        }
        if(unchanged)baseline=root.innerHTML;
        return true;
      }
      function setEditable(enabled){editable=!!enabled;root.contentEditable=String(editable);root.setAttribute('aria-readonly',String(!editable));for(const c of toolbar.querySelectorAll('button,select,input'))c.disabled=!editable;}
      const exec=(name,value=null)=>document.execCommand(name,false,value);
      function activeCell(){const s=getSelection();return (s.anchorNode?.nodeType===1?s.anchorNode:s.anchorNode?.parentElement)?.closest('td,th');}
      function tableCommand(name,value){
        if(name==='table'){
          const [r,c]=String(value||'2x2').split('x').map(Number);if(!Number.isInteger(r)||!Number.isInteger(c)||r<1||c<1||r>30||c>20)return;
          exec('insertHTML','<table><tbody>'+Array.from({length:r},()=>'<tr>'+('<td><br></td>'.repeat(c))+'</tr>').join('')+'</tbody></table><p><br></p>');return;
        }
        const cell=activeCell(),row=cell?.parentElement,table=cell?.closest('table');if(!cell||!table||!root.contains(table))return;
        // Merged cells require a separate layout operation; do not corrupt their grid.
        if(Array.from(table.rows).some(r=>r.cells.length!==row.cells.length||Array.from(r.cells).some(c=>c.colSpan!==1||c.rowSpan!==1)))return;
        const index=cell.cellIndex;let next=cell;
        if(name==='rowAfter'||name==='rowBefore'){
          const newRow=document.createElement('tr');for(const old of row.cells){const n=document.createElement(old.localName);n.innerHTML='<br>';newRow.append(n);}row.insertAdjacentElement(name==='rowAfter'?'afterend':'beforebegin',newRow);next=newRow.cells[index];
        } else if(name==='columnAfter'||name==='columnBefore'){
          for(const r of table.rows){const n=document.createElement(r.cells[index].localName);n.innerHTML='<br>';r.cells[index].insertAdjacentElement(name==='columnAfter'?'afterend':'beforebegin',n);}next=row.cells[index+(name==='columnAfter'?1:0)];
        } else if(name==='deleteRow') {next=row.nextElementSibling?.cells[index]||row.previousElementSibling?.cells[index];row.remove();}
        else if(name==='deleteColumn'){next=row.cells[index+1]||row.cells[index-1];for(const r of Array.from(table.rows))r.cells[index]?.remove();}
        else if(name==='deleteTable'){next=null;table.remove();}
        if(!table.rows.length||!table.querySelector('td,th'))table.remove();
        if(next?.isConnected){const range=document.createRange();range.selectNodeContents(next);range.collapse(true);getSelection().removeAllRanges();getSelection().addRange(range);}remember();
      }
      function command(name,value=''){
        if(!editable||composing)return false;restore();
        if(name==='undo'||name==='redo'){post({action:name});return true;}
        if(['table','rowAfter','rowBefore','columnAfter','columnBefore','deleteRow','deleteColumn','deleteTable'].includes(name))tableCommand(name,value);
        else if(name==='checklist')exec('insertHTML','<ul><li><label><input type="checkbox"> '+(getSelection().toString().replaceAll('&','&amp;').replaceAll('<','&lt;')||text('To Do').replaceAll('&','&amp;').replaceAll('<','&lt;'))+'</label></li></ul>');
        else if(name==='link'){if(!/^(https?:\/\/|mailto:|#)/i.test(value))return false;exec('createLink',value);}
        else if(name==='fontSize'){if(!/^\d{1,2}$/.test(value)||Number(value)<8||Number(value)>72)return false;exec('fontSize','7');const range=getSelection().rangeCount?getSelection().getRangeAt(0):null;for(const n of root.querySelectorAll('font[size="7"]')){if(!range?.intersectsNode(n))continue;n.removeAttribute('size');n.style.fontSize=value+'px';}}
        else if(name==='formatBlock'){if(!['p','h1','h2','h3','h4','pre','blockquote'].includes(value))return false;exec(name,value);}
        else if(['bold','italic','underline','strikeThrough','removeFormat','insertText','fontName','foreColor','hiliteColor','justifyLeft','justifyCenter','justifyRight','justifyFull','insertUnorderedList','insertOrderedList','indent','outdent','unlink','insertHorizontalRule','subscript','superscript'].includes(name))exec(name,value);
        else return false;
        remember();changed();return true;
      }
      function pasteHTML(html){if(!editable||composing)return false;restore();const f=fragment(html,false);const c=document.createElement('div');c.append(f);exec('insertHTML',c.innerHTML);changed();return true;}
      root.addEventListener('input',changed);
      root.addEventListener('compositionstart',()=>{composing=true;post({composing:true});});
      root.addEventListener('compositionend',()=>{composing=false;remember();const html=getHTML();lastEmitted=html;post({composing:false,html});});
      document.addEventListener('selectionchange',remember);
      root.addEventListener('click',e=>{if(e.target.closest('a'))e.preventDefault();});
      root.addEventListener('change',e=>{if(e.target.matches('input[type=checkbox]')){if(!editable){e.target.checked=e.target.hasAttribute('checked');return;}e.target.toggleAttribute('checked',e.target.checked);changed();}});
      root.addEventListener('keydown',e=>{if((e.metaKey||e.ctrlKey)&&e.key.toLowerCase()==='z'){e.preventDefault();post({action:e.shiftKey?'redo':'undo'});}});
      root.addEventListener('paste',e=>{e.preventDefault();if(e.clipboardData?.files.length){post({action:'pasteFiles'});return;}const html=e.clipboardData?.getData('text/html');if(html)pasteHTML(html);else command('insertText',e.clipboardData?.getData('text/plain')||'');});
      root.addEventListener('dragover',e=>e.preventDefault());
      root.addEventListener('drop',e=>{e.preventDefault();});
      // Export the selection through the same restoration path as document storage.
      function copySelection(e,cut){
        const s=getSelection();if(!s.rangeCount||!root.contains(s.anchorNode)||!root.contains(s.focusNode))return;
        const c=document.createElement('div');c.append(s.getRangeAt(0).cloneContents());const html=exported(c);
        e.clipboardData.setData('text/html',html);const t=document.createElement('template');t.innerHTML=html;e.clipboardData.setData('text/plain',t.content.textContent);e.preventDefault();
        if(cut&&editable&&!composing){exec('delete');changed();}
      }
      root.addEventListener('copy',e=>copySelection(e,false));
      root.addEventListener('cut',e=>copySelection(e,true));
      toolbar.addEventListener('mousedown',e=>{remember();if(e.target.closest('button'))e.preventDefault();});
      function button(label,name,title=label){const b=document.createElement('button');b.type='button';b.textContent=label;b.title=title;b.setAttribute('aria-label',title);b.addEventListener('click',()=>command(name));toolbar.append(b);return b;}
      function select(label,items,name){const s=document.createElement('select');s.setAttribute('aria-label',label);s.title=label;for(const [v,t] of items){const o=document.createElement('option');o.value=v;o.textContent=t;s.append(o);}s.addEventListener('change',()=>command(name,s.value));toolbar.append(s);return s;}
      select(text('Paragraph Style'),[['p',text('Body')],['h1',text('Heading 1')],['h2',text('Heading 2')],['h3',text('Heading 3')],['blockquote',text('Quote')],['pre',text('Code')]], 'formatBlock');
      select(text('Font'),[['-apple-system',text('System')],['Arial','Arial'],['Georgia','Georgia'],['Times New Roman','Times'],['Helvetica','Helvetica'],['Apple SD Gothic Neo',text('Gothic')],['AppleMyungjo',text('Myungjo')],['Menlo','Menlo']], 'fontName');
      select(text('Font Size'),['10','12','14','16','18','24','32','48','72'].map(x=>[x,x+' px']),'fontSize');
      for(const [l,n,t] of [['B','bold',text('Bold')],['I','italic',text('Italic')],['U','underline',text('Underline')],['S','strikeThrough',text('Strikethrough')],['x₂','subscript',text('Subscript')],['x²','superscript',text('Superscript')]])button(l,n,t);
      for(const [label,name] of [[text('Text Color'),'foreColor'],[text('Highlight Color'),'hiliteColor']]){const c=document.createElement('input');c.type='color';c.title=label;c.setAttribute('aria-label',label);c.addEventListener('input',()=>command(name,c.value));toolbar.append(c);}
      for(const [l,n,t] of [['≡','justifyLeft',text('Align Left')],['☰','justifyCenter',text('Align Center')],['≣','justifyRight',text('Align Right')],['☷','justifyFull',text('Justify')],[text('• List'),'insertUnorderedList',text('Bulleted List')],[text('1. List'),'insertOrderedList',text('Numbered List')],['☑','checklist',text('Checklist')],['→','indent',text('Indent')],['←','outdent',text('Outdent')],[text('Clear Formatting'),'removeFormat',text('Clear Formatting')]])button(l,n,t);
      function requestValue(label,initial,callback){remember();const d=document.getElementById('original-dialog'),input=document.getElementById('original-dialog-value');document.getElementById('original-dialog-label').textContent=label;input.value=initial;d.onclose=()=>{if(d.returnValue==='ok')callback(input.value);restore();};d.showModal();input.focus();}
      const link=button(text('Link'),'noop',text('Insert Link'));link.addEventListener('click',()=>requestValue(text('Link Address'),'https://',v=>command('link',v)));
      button(text('Remove Link'),'unlink');
      const table=button(text('Table'),'noop',text('Create Table'));table.addEventListener('click',()=>requestValue(text('Rows x Columns (up to 30 x 20)'),'2x2',v=>command('table',v)));
      select(text('Edit Table'),[['',text('Edit Table…')],['rowBefore',text('Add Row Above')],['rowAfter',text('Add Row Below')],['columnBefore',text('Add Column to Left')],['columnAfter',text('Add Column to Right')],['deleteRow',text('Delete Row')],['deleteColumn',text('Delete Column')],['deleteTable',text('Delete Table')]],'noop').addEventListener('change',e=>{command(e.target.value);e.target.value='';});
      const files=button(text('Attach'),'noop',text('Attach Files or Images'));files.addEventListener('click',()=>post({action:'pickFiles'}));
      button('↶','undo',text('Undo'));button('↷','redo',text('Redo'));
      window.originalEditor={load,getHTML,command,pasteHTML,setEditable,updateAttachments};
    })();
    """#
}
