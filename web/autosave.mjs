/** One stable note, serialized writes, and no stale whole-review replacement. */
export class FeedbackAutosave {
  constructor(payload,send,status,{body=null,isDraft=true,action='saveFeedback',discardAction='discardDraft'}={}){
    this.payload=payload;this.send=send;this.status=status;this.savedBody=body;
    this.savedDraft=isDraft;this.next=null;this.running=null;this.finishing=false;
    this.action=action;this.discardAction=discardAction;
  }
  save(body,isDraft=true){
    this.next={body,isDraft};this.status('saving');
    if(!this.running)this.running=this.drain().finally(()=>{this.running=null;});
    return this.running;
  }
  async drain(){
    try{
      while(this.next){
        const next=this.next;this.next=null;
        if(next.body===this.savedBody&&next.isDraft===this.savedDraft)continue;
        for(let attempt=0;;attempt++){
          try{await this.send(this.action,{...this.payload,...next,baseBody:this.savedBody});break;}
          catch(error){if(!error.retryable||attempt>=8)throw error;await new Promise(resolve=>setTimeout(resolve,150));}
        }
        this.savedBody=next.body;this.savedDraft=next.isDraft;
      }
      this.status('saved');
    }catch(error){this.next=null;this.status('error');throw error;}
  }
  async discard(){
    this.finishing=true;
    try{
      if(this.running)await this.running;
      if(this.savedBody!==null&&this.savedDraft)await this.send(this.discardAction,{...this.payload,baseBody:this.savedBody});
    }finally{this.finishing=false;}
  }
}
