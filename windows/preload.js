const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('pet', {
  onState: (cb) => ipcRenderer.on('state', (_e, s) => cb(s)),
  act: (name, ...args) => ipcRenderer.invoke('act', name, ...args),
  mouse: (interactive) => ipcRenderer.send('pet-mouse', interactive),
  click: () => ipcRenderer.send('pet-click'),
  drag: (dx, dy) => ipcRenderer.send('pet-drag', { dx, dy }),
  dragEnd: () => ipcRenderer.send('pet-drag-end'),
  menu: () => ipcRenderer.send('pet-menu'),
  dblclick: () => ipcRenderer.send('pet-dblclick'),
  petted: () => ipcRenderer.send('pet-petted'),
  panelSize: (h) => ipcRenderer.send('panel-size', h),
});
