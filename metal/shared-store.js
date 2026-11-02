/* 공개 링크에서 공동 편집. 읽기/쓰기는 제한된 RPC와 서버 검증을 사용한다. */
(function(root){
  "use strict";
  const copy=x=>JSON.parse(JSON.stringify(x));
  const own=(o,k)=>Object.prototype.hasOwnProperty.call(o,k);
  const object=o=>o!==null&&typeof o==="object"&&!Array.isArray(o);
  function date(s){
    if(typeof s!=="string"||!/^\d{4}-\d{2}-\d{2}$/.test(s))return false;
    const n=new Date(s+"T00:00:00Z");return Number.isFinite(+n)&&n.toISOString().slice(0,10)===s;
  }
  function url(s){
    if(s==="")return true;
    if(typeof s!=="string"||/[\x00-\x20\x7f\\]/.test(s))return false;
    try{const u=new URL(s);return ["https:","http:"].includes(u.protocol)&&!!u.hostname&&!u.username&&!u.password;}catch(e){return false;}
  }
  function keys(o,list){return object(o)&&Object.keys(o).every(k=>list.includes(k));}
  function text(s,max){return typeof s==="string"&&s.length<=max;}
  function validate(p){
    const fail=()=>{throw new Error("공유 데이터 형식 또는 허용 범위를 확인해 주세요");};
    if(!keys(p,["schema","reports","locks","silver","news","latest"])||Object.keys(p).length!==6||p.schema!==1)fail();
    if(!object(p.reports)||!object(p.locks)||!object(p.silver)||!Array.isArray(p.news)||!text(p.latest,10))fail();
    if(Object.keys(p.reports).length>2000||Object.keys(p.silver).length>10000||p.news.length>500)fail();
    for(const [w,r] of Object.entries(p.reports)){
      if(!date(w)||!keys(r,["f","sheet","s","a","c","n"])||Object.keys(r).length!==6||!date(r.f))fail();
      const f=new Date(r.f+"T00:00:00Z"),gap=+new Date(w+"T00:00:00Z")-f;
      if(f.getUTCDay()!==5||gap<0||gap>7*864e5||!text(r.sheet,200)||!text(r.n,20000)||!["s","a","c"].every(k=>text(r[k],20000)))fail();
    }
    for(const [w,v] of Object.entries(p.locks))if(!own(p.reports,w)||typeof v!=="boolean")fail();
    for(const [w,v] of Object.entries(p.silver))if(!date(w)||typeof v!=="number"||!Number.isFinite(v)||v<=0||v>1000000)fail();
    for(const n of p.news){
      if(!keys(n,["m","t","u","s","d"])||Object.keys(n).length!==5||!["Silver","Aluminium","Copper"].includes(n.m)||!text(n.t,2000)||!text(n.s,500)||!text(n.u,2048)||!url(n.u)||!text(n.d,16)||!/^\d{4}-\d{2}-\d{2}( \d{2}:\d{2})?$/.test(n.d)||!date(n.d.slice(0,10)))fail();
      if(n.d.length>10&&(Number(n.d.slice(11,13))>23||Number(n.d.slice(14,16))>59))fail();
    }
    if(p.latest!==""&&!own(p.reports,p.latest))fail();
    if(new TextEncoder().encode(JSON.stringify(p)).length>2*1024*1024)fail();
    return copy(p);
  }
  function fromFiles(comments,mi){
    const p={schema:1,reports:{},locks:{},silver:copy(mi||{}),news:[],latest:""};
    for(const r of comments||[]){p.reports[r.w]={f:r.f,sheet:r.sheet||"",s:r.s||"",a:r.a||"",c:r.c||"",n:r.n||""};p.locks[r.w]=r.sheet!=="(웹 작성)";}
    p.latest=Object.keys(p.reports).sort().pop()||"";return validate(p);
  }
  function create(options){
    const storage=options.storage||root.localStorage,config=options.config||{},seed=validate(options.seed);
    const scope="metalShared.v2:"+(config.url||"unconfigured");
    let client=options.client||null,view=copy(seed),published=null,revision=0;
    let loaded=false,online=false,dirty=false,busy=false,local=false,pending=null,refreshing=false,timestamp="",message="공유 연결 대기";
    let generation=0,timer=null,channel=null,live=false,initialized=false,cacheError=false,refreshAgain=false;
    function read(k,fallback){try{return JSON.parse(storage.getItem(scope+k))||fallback;}catch(e){return fallback;}}
    function write(k,v){try{storage.setItem(scope+k,JSON.stringify(v));return true;}catch(e){cacheError=true;return false;}}
    function workKey(){return local?":work:local":":work:shared";}
    function state(){return {configured:!!config.url&&!!config.publishableKey,loaded,online,dirty,busy,local,live,revision,timestamp,pending:!!pending,message,canEdit:!busy&&(local||loaded)};}
    function status(t){if(t)message=t;if(options.onStatus)options.onStatus({...state(),message:message+(cacheError?" · 기기 백업 실패, 파일 다운로드 필요":"")});}
    function render(){if(options.onRender)options.onRender();status();}
    function stash(){if(dirty)write(workKey(),{revision,payload:view});}
    function change(fn){if(!state().canEdit)return false;fn(view);dirty=true;stash();status(local?"내 작업본 · 로컬 전용 (공유 안 됨)":"내 작업본 · 공유 전");return true;}
    function rowValid(row){
      if(!row||!Number.isSafeInteger(row.revision)||row.revision<1||typeof row.updated_at!=="string")throw new Error("공용 저장본 버전 오류");
      return {...row,payload:validate(row.payload)};
    }
    function accept(row){
      published=row?copy(row.payload):null;revision=row?row.revision:0;timestamp=row?row.updated_at:"";
      view=copy(published||seed);dirty=false;pending=null;if(row)write(":cache",row);render();
    }
    async function refresh(){
      if(!client||local)return;
      if(refreshing||busy){refreshAgain=true;return;}
      refreshing=true;const epoch=generation;
      try{
        const result=await client.from("metal_shared_state").select("revision,payload,updated_at").eq("id","main").maybeSingle();
        if(result.error)throw result.error;
        const row=result.data?rowValid(result.data):null;
        if(epoch!==generation||local)return;
        const firstLoad=!loaded;
        online=true;loaded=true;
        if(dirty){
          if((row?row.revision:0)!==revision)pending=row||{revision:0,payload:seed};
          status(pending?"다른 사람이 변경했습니다 · 내 작업본 보존됨 · 최신본 비교 필요":"내 작업본 · 공유 전");
        }else if(firstLoad||(row?row.revision:0)!==revision||!published){
          message=row?"최신 공유본":"아직 공유본이 없습니다 · 현재 자료를 확인하고 초기 공유하세요";accept(row);
        }else status("최신 공유본");
      }catch(e){if(epoch===generation){online=false;status("공유 연결 실패 · 마지막 수신본/로컬 자료 (최신 여부 확인 불가)");}}
      finally{refreshing=false;status();if(refreshAgain){refreshAgain=false;root.setTimeout(refresh,0);}}
    }
    function onFocus(){refresh();}
    function onVisibility(){if(root.document.visibilityState==="visible")refresh();}
    async function init(){
      if(!config.url||!config.publishableKey){status("공유 연결 필요 · Supabase 설정 후 이용하세요");render();return;}
      if(!/^https:\/\/[^/]+\/?$/.test(config.url)||!config.publishableKey.startsWith("sb_publishable_")){status("공유 설정 오류 · HTTPS 프로젝트 URL과 publishable 키만 입력하세요");return;}
      const cache=read(":cache",null);
      if(cache){try{message="마지막 수신본 · 연결 확인 중";accept(rowValid(cache));}catch(e){/* 손상 캐시는 사용하지 않는다. */}}
      try{
        if(!client){
          if(!root.supabase)await new Promise((resolve,reject)=>{
            const s=root.document.createElement("script");s.src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.49.8/dist/umd/supabase.js";s.onload=resolve;s.onerror=()=>reject(new Error("공유 모듈 다운로드 실패"));root.document.head.appendChild(s);
          });
          client=root.supabase.createClient(config.url,config.publishableKey,{auth:{persistSession:false,autoRefreshToken:false,detectSessionInUrl:false}});
        }
        if(!initialized){
          initialized=true;
          // 이벤트는 알림으로만 사용. 실제 내용은 검증된 전체 snapshot으로 다시 읽는다.
          channel=client.channel("metal-public-state").on("postgres_changes",{event:"*",schema:"public",table:"metal_shared_state",filter:"id=eq.main"},refresh).subscribe(s=>{live=s==="SUBSCRIBED";status();if(live)refresh();});
          timer=root.setInterval(()=>{if(!root.document||root.document.visibilityState==="visible")refresh();},30000);
          if(root.addEventListener)root.addEventListener("focus",onFocus);
          if(root.document)root.document.addEventListener("visibilitychange",onVisibility);
        }
        await refresh();
      }catch(e){status("공유 연결 실패 · 설정과 인터넷 연결을 확인하세요");}
    }
    async function publish(){
      if(local||!loaded||!online||busy)throw new Error("공유 저장소가 연결된 뒤 저장할 수 있습니다");
      if(pending)throw new Error("새 공유본이 있습니다. 최신본을 비교한 뒤 다시 적용해 주세요");
      const payload=validate(view),expected=revision;generation++;busy=true;status("공유 저장 중…");
      try{
        const result=await client.rpc("metal_save",{p_expected_revision:expected,p_payload:payload});
        if(result.error)throw result.error;
        const row=rowValid(Array.isArray(result.data)?result.data[0]:result.data);
        write(workKey(),null);message="공유 저장 완료 ✓";accept(row);
      }catch(e){
        dirty=true;stash();
        if(e.code==="40001"){pending={revision:-1};status("다른 사람이 먼저 저장했습니다 · 내 작업본 보존됨");}
        else{online=false;status("공유 저장 확인 실패 · 작업본 보존됨. 최신본 확인 후 재시도하세요");}
        throw new Error(message);
      }finally{busy=false;render();if(refreshAgain){refreshAgain=false;root.setTimeout(refresh,0);}}
    }
    async function reload(){
      if(busy||local)return;
      stash();dirty=false;pending=null;view=copy(published||seed);render();await refresh();
    }
    function restore(){
      if(!state().canEdit)throw new Error("공유 연결 또는 로컬 전용 모드에서 복원할 수 있습니다");
      const work=read(workKey(),null);if(!work)throw new Error("이 브라우저의 보존된 작업본이 없습니다");
      if(work.revision!==revision)throw new Error("작업본의 기준 버전이 다릅니다. 보존 작업본 백업을 내려받아 최신본과 비교해 주세요");
      view=validate(work.payload);dirty=true;stash();render();status("작업본 복원됨 · 공유 전");
    }
    function useLocal(){
      if(busy||dirty)return false;
      generation++;local=true;view=copy(seed);revision=0;loaded=false;online=false;render();status("로컬 전용 · 공유 안 됨");return true;
    }
    async function useShared(){
      if(busy)return;stash();generation++;local=false;dirty=false;pending=null;view=copy(published||seed);revision=0;loaded=false;render();
      if(client)await refresh();else await init();
    }
    function importPayload(p){const valid=validate(p);if(!state().canEdit)throw new Error("공유 저장소를 연결해 주세요");change(v=>{Object.keys(v).forEach(k=>delete v[k]);Object.assign(v,valid);});render();}
    function drafts(){return read(local?":draft:local":":draft:shared",{});}
    function saveDrafts(d){if(state().canEdit){write(local?":draft:local":":draft:shared",d);status();}}
    return {init,refresh,publish,reload,restore,useLocal,useShared,change,importPayload,drafts,saveDrafts,
      state,view:()=>view,seed:()=>copy(seed),backup:()=>({app:"metal-shared-backup",version:1,revision,payload:copy(view),drafts:copy(drafts())}),
      storedWork:()=>read(workKey(),null),pending:()=>pending?copy(pending):null,
      stop:()=>{if(timer)root.clearInterval(timer);if(channel)client.removeChannel(channel);if(root.removeEventListener)root.removeEventListener("focus",onFocus);if(root.document)root.document.removeEventListener("visibilitychange",onVisibility);}};
  }
  root.MetalShared={create,validate,fromFiles,safeUrl:url,isDate:date};
})(typeof window!=="undefined"?window:globalThis);
