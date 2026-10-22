import ctypes as c
from ctypes import wintypes as w
import subprocess,time,json,sys
from pathlib import Path
from PIL import Image
u=c.WinDLL('user32'); g=c.WinDLL('gdi32')
u.GetWindow.argtypes=[w.HWND,w.UINT];u.GetWindow.restype=w.HWND
for name,types,result in [('SendMessageW',[w.HWND,w.UINT,w.WPARAM,w.LPARAM],c.c_ssize_t),('GetDC',[w.HWND],w.HDC),('GetDpiForWindow',[w.HWND],w.UINT),('IsZoomed',[w.HWND],w.BOOL),('IsIconic',[w.HWND],w.BOOL),('IsWindowVisible',[w.HWND],w.BOOL),('GetWindowThreadProcessId',[w.HWND,c.POINTER(w.DWORD)],w.DWORD),('GetClientRect',[w.HWND,c.POINTER(w.RECT)],w.BOOL),('ClientToScreen',[w.HWND,c.POINTER(w.POINT)],w.BOOL),('PrintWindow',[w.HWND,w.HDC,w.UINT],w.BOOL),('ReleaseDC',[w.HWND,w.HDC],c.c_int)]:
 f=getattr(u,name);f.argtypes=types;f.restype=result
for name,types,result in [('CreateCompatibleDC',[w.HDC],w.HDC),('CreateCompatibleBitmap',[w.HDC,c.c_int,c.c_int],w.HBITMAP),('SelectObject',[w.HDC,w.HGDIOBJ],w.HGDIOBJ),('DeleteObject',[w.HGDIOBJ],w.BOOL),('DeleteDC',[w.HDC],w.BOOL)]:
 f=getattr(g,name);f.argtypes=types;f.restype=result
class BI(c.Structure):
 _fields_=[('size',w.DWORD),('width',w.LONG),('height',w.LONG),('planes',w.WORD),('bits',w.WORD),('compression',w.DWORD),('imageSize',w.DWORD),('xp',w.LONG),('yp',w.LONG),('used',w.DWORD),('important',w.DWORD)]
g.GetDIBits.argtypes=[w.HDC,w.HBITMAP,w.UINT,w.UINT,c.c_void_p,c.POINTER(BI),w.UINT]
root=Path(__file__).resolve().parent.parent
exe=Path(sys.argv[1]).resolve() if len(sys.argv)>1 else root/'apps/client/build/windows/vs2026/runner/Debug/viora_client.exe'
checks={}
def wait(check):
 for _ in range(100):
  if check(): return
  time.sleep(.05)
 raise AssertionError('Window state timeout')
with (root/'artifacts/native-frame-stderr.txt').open('w') as error:
 p=subprocess.Popen([str(exe)],cwd=exe.parent,stdout=subprocess.DEVNULL,stderr=error,creationflags=0x08000000)
 try:
  found=[]
  @c.WINFUNCTYPE(w.BOOL,w.HWND,w.LPARAM)
  def enum(hwnd,_):
   pid=w.DWORD();u.GetWindowThreadProcessId(hwnd,c.byref(pid))
   if pid.value==p.pid and u.IsWindowVisible(hwnd):found.append(hwnd)
   return True
  def find():
   u.EnumWindows(enum,0)
   return bool(found)
  wait(find); hwnd=found[0];time.sleep(1)
  rect=w.RECT();u.GetClientRect(hwnd,c.byref(rect));dpi=u.GetDpiForWindow(hwnd)
  scale=lambda n:round(n*dpi/96)
  def screen(x,y):
   pt=w.POINT(x,y);u.ClientToScreen(hwnd,c.byref(pt));return ((pt.y&65535)<<16)|(pt.x&65535)
  def hit(x,y):return u.SendMessageW(hwnd,0x84,0,screen(x,y))
  assert hit(scale(100),scale(19))==2;checks['caption_drag_region']=True
  assert hit(scale(100),1)==12;checks['top_resize_region']=True
  child=u.GetWindow(hwnd,5);assert child
  assert u.SendMessageW(child,0x84,0,screen(1,scale(100)))==-1
  assert u.SendMessageW(child,0x84,0,screen(rect.right//2,rect.bottom-1))==-1
  assert hit(1,scale(100))==10 and hit(rect.right//2,rect.bottom-1)==15
  checks['resize_through_flutter_edges']=True
  assert hit(rect.right-scale(23),scale(19))==20
  assert hit(rect.right-scale(69),scale(19))==9
  assert hit(rect.right-scale(115),scale(19))==8;checks['caption_buttons']=True
  def click(button,x):
   pos=screen(x,scale(19));u.SendMessageW(hwnd,0xa1,button,pos);u.SendMessageW(hwnd,0xa2,button,pos)
  click(9,rect.right-scale(69));wait(lambda:u.IsZoomed(hwnd));checks['maximize']=True
  u.GetClientRect(hwnd,c.byref(rect));click(9,rect.right-scale(69));wait(lambda:not u.IsZoomed(hwnd));checks['restore']=True
  u.SendMessageW(hwnd,0xa3,2,screen(scale(100),scale(19)));wait(lambda:u.IsZoomed(hwnd))
  u.SendMessageW(hwnd,0xa3,2,screen(scale(100),scale(19)));wait(lambda:not u.IsZoomed(hwnd));checks['double_click_caption']=True
  u.GetClientRect(hwnd,c.byref(rect));click(8,rect.right-scale(115));wait(lambda:u.IsIconic(hwnd));checks['minimize']=True
  u.SendMessageW(hwnd,0x112,0xf120,0);wait(lambda:not u.IsIconic(hwnd));time.sleep(.3)
  u.GetClientRect(hwnd,c.byref(rect))
  source=u.GetDC(hwnd);dc=g.CreateCompatibleDC(source);bitmap=g.CreateCompatibleBitmap(source,rect.right,rect.bottom);old=g.SelectObject(dc,bitmap)
  assert u.PrintWindow(hwnd,dc,2)
  info=BI();info.size=c.sizeof(BI);info.width=rect.right;info.height=-rect.bottom;info.planes=1;info.bits=32
  pixels=c.create_string_buffer(rect.right*rect.bottom*4);g.SelectObject(dc,old)
  assert g.GetDIBits(dc,bitmap,0,rect.bottom,pixels,c.byref(info),0)
  Image.frombytes('RGB',(rect.right,rect.bottom),pixels.raw,'raw','BGRX').crop((0,0,rect.right,scale(38))).save(root/'artifacts/native-titlebar-preview-03.png')
  g.DeleteObject(bitmap);g.DeleteDC(dc);u.ReleaseDC(hwnd,source)
  click(20,rect.right-scale(23));p.wait(timeout=8);assert p.returncode==0;checks['close']=True
 finally:
  if p.poll() is None:p.terminate();p.wait(timeout=5)
print(json.dumps(checks,indent=2))
