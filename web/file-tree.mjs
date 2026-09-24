const svg=path=>`<svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${path}</svg>`;
const folderIcon=svg('<path d="M2.5 5.5h5l1.5 2h8.5v9h-15z"/><path d="M2.5 7.5v-3h5l1.5 1.5h8.5v1.5"/>');
const fileIcon=svg('<path d="M5 2.5h6l4 4v11H5z"/><path d="M11 2.5v4h4M7.5 10h5M7.5 13h5"/>');
const chevron=svg('<path d="m7 5 5 5-5 5"/>');

export class FileTree {
  constructor({element,host,open}) {
    Object.assign(this,{element,host,open});
    this.expanded=new Set(['']);this.cache=new Map();this.loading=new Map();this.errors=new Map();this.versions=new Map();
    this.selected='';this.focused='';this.workspace=null;
    element.addEventListener('click',event=>{
      const retry=event.target.closest('[data-retry]');
      if(retry){this.load(retry.dataset.retry,true);return;}
      const row=event.target.closest('.file-row');if(!row)return;
      const item=row.parentElement;this.focus(item.dataset.path);
      this.activate(item);
    });
    element.addEventListener('focusin',event=>{
      const item=event.target.closest('[role=treeitem]');if(item)this.focused=item.dataset.path;
    });
    element.addEventListener('keydown',event=>this.key(event));
  }
  update(workspace) {
    if(!workspace)return;
    if(this.workspace?.path!==workspace.path){
      this.cache.clear();this.expanded=new Set(['']);this.errors.clear();this.versions.clear();this.loading.clear();
      this.workspace=workspace;this.load('');
    }
    const selected=workspace.selectedPath??'';
    if(this.selected!==selected){this.selected=selected;this.reveal(this.selected);this.render();}
  }
  async load(path,force=false) {
    if(!force&&this.loading.has(path))return this.loading.get(path);
    if(!force&&this.cache.has(path))return;
    const version=(this.versions.get(path)??0)+1,root=this.workspace.path;
    this.versions.set(path,version);this.errors.delete(path);
    const task=(async()=>{
      try{
        const {entries}=await this.host('listDirectory',{path});
        if(this.workspace.path!==root||this.versions.get(path)!==version)return;
        for(const old of this.cache.get(path)??[]){
          if(old.isDirectory&&!entries.some(entry=>entry.path===old.path&&entry.enabled))this.forget(old.path);
        }
        this.cache.set(path,entries);
        for(const child of entries){if(child.isDirectory&&child.enabled&&this.expanded.has(child.path))this.load(child.path);}
      }catch(error){if(this.versions.get(path)===version)this.errors.set(path,error.message);}
      finally{
        if(!this.expanded.has(path))this.host('unwatchDirectory',{path}).catch(()=>{});
        if(this.versions.get(path)===version){this.loading.delete(path);this.render();}
      }
    })();
    this.loading.set(path,task);this.render();return task;
  }
  forget(path) {
    for(const key of [...this.expanded])if(key===path||key.startsWith(path+'/'))this.expanded.delete(key);
    for(const key of [...this.cache.keys()])if(key===path||key.startsWith(path+'/'))this.cache.delete(key);
    for(const key of [...this.versions.keys()])if(key===path||key.startsWith(path+'/')){
      this.versions.set(key,this.versions.get(key)+1);this.loading.delete(key);this.errors.delete(key);
    }
    this.host('unwatchDirectory',{path}).catch(()=>{});
  }
  async reveal(path) {
    const parts=path.split('/');parts.pop();let parent='';
    await this.load('');
    for(const part of parts){
      const next=parent?parent+'/'+part:part;
      if(!this.cache.get(parent)?.some(entry=>entry.path===next&&entry.isDirectory&&entry.enabled))return;
      this.expanded.add(next);await this.load(next);parent=next;
    }
    this.render();
    this.items().find(item=>item.dataset.path===path)?.querySelector('.file-row')?.scrollIntoView({block:'nearest'});
  }
  async refresh() {
    await this.load('',true);
    for(const path of [...this.expanded])if(path)await this.load(path,true);
  }
  changed(path) {if(this.expanded.has(path))this.load(path,true);else this.cache.delete(path);}
  items() {return [...this.element.querySelectorAll('[role=treeitem]')];}
  focus(path) {
    const item=this.items().find(item=>item.dataset.path===path);if(!item)return;
    this.focused=path;this.items().forEach(row=>row.tabIndex=row===item?0:-1);
    item.focus({preventScroll:true});item.querySelector('.file-row').scrollIntoView({block:'nearest'});
  }
  activate(item) {
    if(item.getAttribute('aria-disabled')==='true')return;
    const path=item.dataset.path;
    if(item.hasAttribute('aria-expanded')){
      if(this.expanded.has(path)){this.forget(path);this.render();}
      else{this.expanded.add(path);this.load(path);this.render();}
    }else this.open(path);
  }
  key(event) {
    const item=event.target.closest('[role=treeitem]');if(!item)return;
    const rows=this.items(),index=rows.indexOf(item),path=item.dataset.path;
    const directory=item.hasAttribute('aria-expanded'),expanded=this.expanded.has(path);
    let next;
    switch(event.key){
      case 'ArrowDown':next=rows[Math.min(rows.length-1,index+1)];break;
      case 'ArrowUp':next=rows[Math.max(0,index-1)];break;
      case 'Home':next=rows[0];break;
      case 'End':next=rows.at(-1);break;
      case 'ArrowRight':if(directory&&!expanded)this.activate(item);else if(directory)next=item.querySelector('[role=treeitem]');break;
      case 'ArrowLeft':if(directory&&expanded)this.activate(item);else next=item.parentElement.closest('[role=treeitem]');break;
      case 'Enter':case ' ':this.activate(item);break;
      default:return;
    }
    event.preventDefault();if(next)this.focus(next.dataset.path);
  }
  render() {
    if(!this.workspace)return;
    const restore=this.element.contains(document.activeElement),top=this.element.scrollTop;
    const fragment=document.createDocumentFragment();
    const branch=(path,parent,depth)=>{
      const entries=this.cache.get(path);
      if(!entries||!entries.length){
        const empty=document.createElement('li');empty.className='file-tree-message';empty.setAttribute('role','none');
        empty.textContent=this.errors.get(path)??(this.loading.has(path)?'Loading…':path?'Empty folder':'This folder is empty.');
        if(this.errors.has(path)){const retry=document.createElement('button');retry.textContent='Try again';retry.dataset.retry=path;empty.append(retry);}
        parent.append(empty);return;
      }
      if(this.errors.has(path)){const message=document.createElement('li');message.className='file-tree-message';message.setAttribute('role','none');message.textContent=this.errors.get(path);parent.append(message);}
      entries.forEach((entry,index)=>{
        const item=document.createElement('li');item.setAttribute('role','treeitem');item.dataset.path=entry.path;
        item.setAttribute('aria-label',entry.name);item.setAttribute('aria-level',depth+1);item.setAttribute('aria-posinset',index+1);item.setAttribute('aria-setsize',entries.length);
        item.tabIndex=-1;item.title=entry.reason??entry.path;
        item.setAttribute('aria-disabled',String(!entry.enabled));item.setAttribute('aria-selected',String(entry.path===this.selected));
        if(entry.isDirectory)item.setAttribute('aria-expanded',String(this.expanded.has(entry.path)));
        if(this.loading.has(entry.path))item.setAttribute('aria-busy','true');
        const row=document.createElement('div');row.className='file-row';row.style.setProperty('--depth',depth);
        const arrow=document.createElement('span');arrow.className='file-chevron';if(entry.isDirectory)arrow.innerHTML=chevron;
        const icon=document.createElement('span');icon.className='file-icon';icon.innerHTML=entry.isDirectory?folderIcon:fileIcon;
        const label=document.createElement('span');label.className='file-label';label.textContent=entry.name;
        row.append(arrow,icon,label);item.append(row);parent.append(item);
        if(entry.isDirectory&&this.expanded.has(entry.path)){
          const children=document.createElement('ul');children.setAttribute('role','group');item.append(children);branch(entry.path,children,depth+1);
        }
      });
    };
    branch('',fragment,0);this.element.replaceChildren(fragment);this.element.scrollTop=top;
    const rows=this.items(),focus=rows.find(item=>item.dataset.path===this.focused)??rows.find(item=>item.dataset.path===this.selected)??rows[0];
    if(focus){focus.tabIndex=0;if(restore)focus.focus({preventScroll:true});}
  }
}
