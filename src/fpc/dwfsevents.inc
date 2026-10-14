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
  MacOsApi.MacOSAll;
{$ELSE}
  MacOSAll;
{$ENDIF}

// Not in the headers of FPC 3.2
function dispatch_queue_create(aLabel: PAnsiChar; aAttr: Pointer): dispatch_queue_t; cdecl; external name 'dispatch_queue_create';
procedure dispatch_release(aObject: Pointer); cdecl; external name 'dispatch_release';
procedure FSEventStreamSetDispatchQueue(aStream: FSEventStreamRef; aQueue: dispatch_queue_t); cdecl; external name 'FSEventStreamSetDispatchQueue';

Type
  TFSEventsDriver = Class(TDirListDriver)
  Protected
  Type
    { TFSEventsData }
    TFSEventsData = class(TDirData)
    private
      FStream : FSEventStreamRef;
      // Set from the stream's own thread
      FChanged : Longint;
    end;
  Private
    FQueue : dispatch_queue_t;
    function Changed : cardinal;
  Public
    Procedure Init; override;
    function DoCheck : cardinal; override;
    Procedure Done; override;
  end;

procedure StreamCallback(streamRef: ConstFSEventStreamRef; clientCallBackInfo: UnivPtr; numEvents: size_t;
  eventPaths: UnivPtr; eventFlags: FSEventStreamEventFlagsPtr; eventIds: FSEventStreamEventIdPtr); mwpascal;
begin
  InterLockedExchange(TFSEventsDriver.TFSEventsData(clientCallBackInfo).FChanged,1);
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
  For I:=0 to Watch.Watches.Count-1 do
    begin
    Watch.Watches[i].DriverData.Free;
    lData:=TFSEventsData.Create(Watch,Watch.Watches[i]);
    Watch.Watches[i].DriverData:=lData;
    lData.InitWatch;
    lPath:=CFStringCreateWithFileSystemRepresentation(Nil,PAnsiChar(BD+Watch.Watches[i].Path));
    lPaths:=CFArrayCreate(Nil,@lPath,1,@kCFTypeArrayCallBacks);
    lContext:=Default(FSEventStreamContext);
    lContext.info:=lData;
    lData.FStream:=FSEventStreamCreate(Nil,@StreamCallback,@lContext,lPaths,High(FSEventStreamEventId),0.05,kFSEventStreamCreateFlagNoDefer);
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

var
  lUntil : QWord;

begin
  lUntil:=GetTickCount64+Watch.CheckTimeOut;
  Repeat
    Result:=Changed;
    if (Result=0) and (GetTickCount64<lUntil) then
      Sleep(10);
  until (Result>0) or (GetTickCount64>=lUntil) or Terminated;
end;

procedure TFSEventsDriver.Done;

var
  I : Integer;
  lData : TFSEventsData;

begin
  For I:=0 to Watch.Watches.Count-1 do
    begin
    lData:=TFSEventsData(Watch.Watches[i].DriverData);
    if Assigned(lData) and Assigned(lData.FStream) then
      begin
      FSEventStreamStop(lData.FStream);
      FSEventStreamInvalidate(lData.FStream);
      FSEventStreamRelease(lData.FStream);
      lData.FStream:=Nil;
      end;
    end;
  if Assigned(FQueue) then
    dispatch_release(FQueue);
  FQueue:=Nil;
end;
