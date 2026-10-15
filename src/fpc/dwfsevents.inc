{ **********************************************************************
    File/Directory watch component: FSEvents based implementation, for
    macOS, written for FileEye to be offered back to Free Pascal.

    kqueue on a folder hears names come and go, but not a file inside it
    being written, so an in-place save went unseen.  An FSEvents stream
    does hear that.  It only says which folder changed; the directory
    listing, as for kqueue and Windows, says what.

    See the file COPYING.FPC, included in this distribution,
    for details about the copyright.
 **********************************************************************}

uses
{$IFDEF FPC_DOTTEDUNITS}
  UnixApi.Base, MacOsApi.MacOSAll;
{$ELSE}
  baseunix, MacOSAll;
{$ENDIF}

// FSEvents is in CoreServices; a program without the LCL links nothing else for it
{$linkframework CoreServices}

// libdispatch, declared as fcl-net's networkframeworksslsockets does
function dispatch_queue_create(label_: PAnsiChar; attr: Pointer): dispatch_queue_t; cdecl; external;
procedure dispatch_release(obj: Pointer); cdecl; external;
function dispatch_semaphore_create(value: PtrInt): Pointer; cdecl; external;
function dispatch_semaphore_signal(dsema: Pointer): PtrInt; cdecl; external;
function dispatch_semaphore_wait(dsema: Pointer; timeout: QWord): PtrInt; cdecl; external;
function dispatch_time(when: QWord; delta: Int64): QWord; cdecl; external;
// FileEye: in univint on main, not in the units FPC 3.2.4 installs
procedure FSEventStreamSetDispatchQueue(streamRef: FSEventStreamRef; q: dispatch_queue_t); cdecl; external;

Type
  TFSEventsDriver = Class(TDirListDriver)
  Protected
  Type
    { TFSEventsData }
    TFSEventsData = class(TDirData)
    private
      FStream : FSEventStreamRef;
      FSignal : Pointer;
      // Set from the stream's own thread
      FChanged : Longint;
    end;
  Private
    FQueue : dispatch_queue_t;
    FSignal : Pointer;
    function Changed : cardinal;
  Public
    Procedure Init; override;
    function DoCheck : cardinal; override;
    Procedure Done; override;
  end;

procedure StreamCallback(streamRef: ConstFSEventStreamRef; clientCallBackInfo: UnivPtr; numEvents: size_t;
  eventPaths: UnivPtr; eventFlags: FSEventStreamEventFlagsPtr; eventIds: FSEventStreamEventIdPtr); mwpascal;

var
  lData : TFSEventsDriver.TFSEventsData absolute clientCallBackInfo;

begin
  InterLockedExchange(lData.FChanged,1);
  dispatch_semaphore_signal(lData.FSignal);
end;

procedure TFSEventsDriver.Init;

var
  I : Integer;
  lData : TFSEventsData;
  BD : String;
  lPath : CFStringRef;
  lPaths : CFArrayRef;
  lContext : FSEventStreamContext;

begin
  BD:=Watch.BaseDir;
  if BD<>'' then
    BD:=IncludeTrailingPathDelimiter(BD);
  FQueue:=dispatch_queue_create('DirWatch',Nil);
  FSignal:=dispatch_semaphore_create(0);
  For I:=0 to Watch.Watches.Count-1 do
    begin
    Watch.Watches[i].DriverData.Free;
    lData:=TFSEventsData.Create(Watch,Watch.Watches[i]);
    Watch.Watches[i].DriverData:=lData;
    lData.FSignal:=FSignal;
    lData.InitWatch;
    lPath:=CFStringCreateWithFileSystemRepresentation(Nil,PAnsiChar(BD+Watch.Watches[i].Path));
    lPaths:=CFArrayCreate(Nil,@lPath,1,@kCFTypeArrayCallBacks);
    lContext:=Default(FSEventStreamContext);
    lContext.info:=lData;
    lData.FStream:=FSEventStreamCreate(Nil,@StreamCallback,@lContext,lPaths,FSEventStreamEventId(kFSEventStreamEventIdSinceNow),0.05,kFSEventStreamCreateFlagNoDefer);
    CFRelease(lPaths);
    CFRelease(lPath);
    FSEventStreamSetDispatchQueue(lData.FStream,FQueue);
    FSEventStreamStart(lData.FStream);
    end;
end;

function TFSEventsDriver.Changed: cardinal;

var
  I : Integer;
  lData : TFSEventsData;

begin
  Result:=0;
  For I:=0 to Watch.Watches.Count-1 do
    begin
    lData:=TFSEventsData(Watch.Watches[i].DriverData);
    if Assigned(lData) and (InterLockedExchange(lData.FChanged,0)=1) then
      Result:=Result+lData.Check;
    end;
end;

function TFSEventsDriver.DoCheck: cardinal;

begin
  Result:=Changed;
  // DISPATCH_TIME_NOW is 0
  if (Result=0) and (Watch.CheckTimeOut>0) then
    if dispatch_semaphore_wait(FSignal,dispatch_time(0,Int64(Watch.CheckTimeOut)*1000000))=0 then
      Result:=Changed;
end;

procedure TFSEventsDriver.Done;

var
  I : Integer;
  D : TObject;
  lData : TFSEventsData absolute D;

begin
  if Assigned(Watch) then
    For I:=0 to Watch.Watches.Count-1 do
      begin
      D:=Watch.Watches[i].DriverData;
      Watch.Watches[i].DriverData:=Nil;
      if Assigned(lData) and Assigned(lData.FStream) then
        begin
        FSEventStreamStop(lData.FStream);
        FSEventStreamInvalidate(lData.FStream);
        FSEventStreamRelease(lData.FStream);
        end;
      FreeAndNil(D);
      end;
  if Assigned(FQueue) then
    dispatch_release(FQueue);
  FQueue:=Nil;
  if Assigned(FSignal) then
    dispatch_release(FSignal);
  FSignal:=Nil;
end;
