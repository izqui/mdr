// Selection endpoints are DOM points, which can fall between mapped spans or
// at the first character of the following block. Search only the endpoints;
// never scan every span in a long selection or include a zero-length overlap.
export function sourceSelection(range, spans) {
  const cursor=document.createRange(),end=range.cloneRange();end.collapse(false);
  const lowerBound=predicate=>{let lo=0,hi=spans.length;while(lo<hi){const mid=(lo+hi)>>>1;if(predicate(spans[mid].element))lo=mid+1;else hi=mid;}return lo;};
  let first=lowerBound(span=>{
    cursor.selectNodeContents(span);cursor.collapse(false);
    return cursor.compareBoundaryPoints(Range.START_TO_START,range)<=0;
  });
  let last=lowerBound(span=>{
    cursor.selectNodeContents(span);cursor.collapse(true);
    return cursor.compareBoundaryPoints(Range.START_TO_START,end)<0;
  })-1;
  const offset=(span,node,position,fallback)=>{
    if(!span.contains(node))return fallback;
    cursor.selectNodeContents(span);cursor.setEnd(node,position);return cursor.toString().length;
  };
  while(first<=last){const span=spans[first].element;if(offset(span,range.startContainer,range.startOffset,0)<span.textContent.length)break;first++;}
  while(last>=first){const span=spans[last].element;if(offset(span,range.endContainer,range.endOffset,span.textContent.length)>0)break;last--;}
  if(first>last)return null;
  const a=spans[first].element,b=spans[last].element;
  const clipped=range.cloneRange();
  if(!a.contains(range.startContainer)){
    const text=document.createTreeWalker(a,NodeFilter.SHOW_TEXT).nextNode();
    clipped.setStart(text,0);
  }
  if(!b.contains(range.endContainer)){
    const walker=document.createTreeWalker(b,NodeFilter.SHOW_TEXT);let text,lastText;
    while(text=walker.nextNode())lastText=text;
    clipped.setEnd(lastText,lastText.length);
  }
  return {first:a,last:b,startOffset:offset(a,clipped.startContainer,clipped.startOffset,0),
    endOffset:offset(b,clipped.endContainer,clipped.endOffset,b.textContent.length),range:clipped};
}

// Keep ordinary text/word/paragraph selection native. Only take over scrolling
// near an edge, where WebKit's fixed, slow autoscroll makes long reviews tiring.
export function installSelectionScrolling({article,scroller,onStart,onEnd}) {
  let drag=null,frame=0,lastTime=0,generation=0;
  const stopFrame=()=>{cancelAnimationFrame(frame);frame=0;lastTime=0;};
  const viewport=element=>{
    const box=element.getBoundingClientRect(),outer=scroller.getBoundingClientRect();
    return {left:Math.max(box.left,outer.left),right:Math.min(box.right,outer.right),
      top:Math.max(box.top,outer.top),bottom:Math.min(box.bottom,outer.bottom)};
  };
  const speed=(coordinate,low,high)=>{
    const band=Math.min(56,(high-low)/4);
    if(coordinate<low+band)return -Math.min(1600,120+Math.max(0,(low+band-coordinate)/band)*1000);
    if(coordinate>high-band)return Math.min(1600,120+Math.max(0,(coordinate-high+band)/band)*1000);
    return 0;
  };
  function scrollTarget(){
    // A long code pane scrolls first, then hands off to the document at its end.
    const pane=drag.pane;
    for(const element of pane?[pane,scroller]:[scroller]){
      const box=viewport(element),velocity=speed(drag.y,box.top,box.bottom);
      if((velocity<0&&element.scrollTop>0)||(velocity>0&&element.scrollTop+element.clientHeight<element.scrollHeight-1))return {element,box,velocity};
      if(pane===element&&drag.y>box.top&&drag.y<box.bottom)return null;
    }
    return null;
  }
  function extend(box,gesture=drag){
    const x=Math.max(box.left+2,Math.min(box.right-2,gesture.x));
    const y=Math.max(box.top+2,Math.min(box.bottom-2,gesture.y));
    const point=document.caretRangeFromPoint?.(x,y);
    if(!point||!article.contains(point.startContainer))return;
    const selected=getSelection();
    if(!article.contains(selected?.anchorNode))return;
    selected.extend(point.startContainer,point.startOffset);
  }
  function tick(time){
    frame=0;if(!drag)return;
    const target=scrollTarget();if(!target){lastTime=0;return;}
    drag.lastScroller=target.element;
    const elapsed=lastTime?Math.min(32,time-lastTime):16;lastTime=time;
    target.element.scrollBy({top:target.velocity*elapsed/1000,behavior:'instant'});
    extend(target.box);frame=requestAnimationFrame(tick);
  }
  article.addEventListener('mousedown',event=>{
    if(event.button!==0||event.target.closest('button,input,textarea,[contenteditable=true]'))return;
    drag={generation:++generation,x:event.clientX,y:event.clientY,startX:event.clientX,startY:event.clientY,moved:false,
      pane:event.target.closest('pre')};
    onStart();
  });
  document.addEventListener('mousemove',event=>{
    if(!drag)return;
    if(!(event.buttons&1)){finish(true);return;}
    drag.x=event.clientX;drag.y=event.clientY;
    drag.moved ||= Math.hypot(drag.x-drag.startX,drag.y-drag.startY)>3;
    if(!drag.moved)return;
    const target=scrollTarget();
    if(target){
      event.preventDefault();extend(target.box);
      if(!frame)frame=requestAnimationFrame(tick);
    }else stopFrame();
  },{capture:true});
  function finish(released=false){
    if(!drag)return;
    const completed=drag;
    drag=null;stopFrame();
    // WebKit can extend again during its final native autoscroll/mouseup. Keep
    // the endpoint at the last visible line after that default action finishes.
    if(released&&completed.lastScroller){
      requestAnimationFrame(()=>{
        if(completed.generation!==generation)return;
        extend(viewport(completed.lastScroller),completed);onEnd(true);
      });
    }else onEnd(released);
  }
  document.addEventListener('mouseup',event=>{if(event.button===0)finish(true);});
  window.addEventListener('blur',()=>finish());
  article.addEventListener('dragstart',()=>finish());
  document.addEventListener('keydown',event=>{if(event.key==='Escape')finish();});
  document.addEventListener('visibilitychange',()=>{if(document.hidden)finish();});
  return {get dragging(){return !!drag;}};
}
