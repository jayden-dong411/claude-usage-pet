// Where Claude and Claude Code keep their data on this machine.
const os = require('os');
const path = require('path');

const home = os.homedir();
const isWin = process.platform === 'win32';
const isMac = process.platform === 'darwin';

const claudeDir = path.join(home, '.claude');

/** Claude desktop (Electron) user-data folder. */
function desktopDataDir() {
  if (isWin) return path.join(process.env.APPDATA || path.join(home, 'AppData', 'Roaming'), 'Claude');
  if (isMac) return path.join(home, 'Library', 'Application Support', 'Claude');
  return path.join(process.env.XDG_CONFIG_HOME || path.join(home, '.config'), 'Claude');
}

module.exports = {
  home,
  isWin,
  isMac,
  claudeDir,
  sessionsDir: path.join(claudeDir, 'sessions'),
  projectsDir: path.join(claudeDir, 'projects'),
  credentialsFile: path.join(claudeDir, '.credentials.json'),
  desktopDataDir,
};
