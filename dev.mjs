// Runs the Spring Boot backend and the Vite frontend together.
// Ctrl+C (or either server exiting) shuts both down.
//
//   node dev.mjs
import { execSync, spawn } from 'node:child_process'
import { existsSync, readdirSync, readFileSync } from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import process from 'node:process'
import { fileURLToPath } from 'node:url'

const root = path.dirname(fileURLToPath(import.meta.url))
const isWindows = process.platform === 'win32'

// The JDK major version the backend's toolchain asks for, e.g. JavaLanguageVersion.of(26).
function requiredJavaVersion() {
  const buildFile = readFileSync(path.join(root, 'nomanualcode', 'build.gradle'), 'utf8')
  return buildFile.match(/JavaLanguageVersion\.of\((\d+)\)/)?.[1] ?? '26'
}

// Major version of the JDK at `home`, read from its `release` file (JAVA_VERSION="26.0.2").
function jdkVersion(home) {
  try {
    const release = readFileSync(path.join(home, 'release'), 'utf8')
    return release.match(/^JAVA_VERSION="(\d+)/m)?.[1]
  } catch {
    return undefined
  }
}

// Gradle has to run on the JDK the build targets; a newer one can break it. Keep JAVA_HOME if it
// already matches, otherwise look for a matching JDK in the usual install locations.
function findJavaHome(version) {
  if (process.env.JAVA_HOME && jdkVersion(process.env.JAVA_HOME) === version) {
    return process.env.JAVA_HOME
  }
  const searchDirs = [
    path.join(os.homedir(), '.jdks'),
    path.join(os.homedir(), '.gradle', 'jdks'),
    path.join(os.homedir(), '.sdkman', 'candidates', 'java'),
    'C:\\Program Files\\Java',
    'C:\\Program Files\\Eclipse Adoptium',
    'C:\\Program Files\\Amazon Corretto',
    'C:\\Program Files\\Microsoft',
    '/usr/lib/jvm',
    '/Library/Java/JavaVirtualMachines',
    path.join(os.homedir(), 'Library', 'Java', 'JavaVirtualMachines'),
  ]
  for (const dir of searchDirs) {
    let entries
    try {
      entries = readdirSync(dir)
    } catch {
      continue
    }
    for (const entry of entries.sort().reverse()) {
      // macOS bundles keep the JDK under Contents/Home.
      for (const home of [path.join(dir, entry), path.join(dir, entry, 'Contents', 'Home')]) {
        if (jdkVersion(home) === version) return home
      }
    }
  }
  return undefined
}

const javaVersion = requiredJavaVersion()
const javaHome = findJavaHome(javaVersion)
if (javaHome) {
  console.log(`Backend will use JDK ${javaVersion}: ${javaHome}`)
} else {
  console.warn(`No JDK ${javaVersion} found; the backend will use JAVA_HOME as-is (${process.env.JAVA_HOME ?? 'unset'}).`)
}

const services = [
  {
    name: 'api',
    color: 36, // cyan
    cwd: path.join(root, 'nomanualcode'),
    command: isWindows ? '.\\gradlew.bat bootRun' : './gradlew bootRun',
    port: 8080,
    env: javaHome ? { JAVA_HOME: javaHome } : {},
  },
  {
    name: 'ui',
    color: 35, // magenta
    cwd: path.join(root, 'nomanualcodeui'),
    command: 'npm run dev',
    port: 5173,
  },
]

const children = []
let shuttingDown = false

function log(service, line) {
  console.log(`\x1b[${service.color}m[${service.name}]\x1b[0m ${line}`)
}

function start(service) {
  const child = spawn(service.command, {
    cwd: service.cwd,
    env: { ...process.env, ...service.env },
    shell: true,
    stdio: ['ignore', 'pipe', 'pipe'],
    // On Unix, put each server in its own process group so the whole tree can be killed at once.
    detached: !isWindows,
  })

  for (const stream of [child.stdout, child.stderr]) {
    let buffer = ''
    stream.on('data', (chunk) => {
      buffer += chunk
      const lines = buffer.split(/\r?\n/)
      buffer = lines.pop()
      lines.forEach((line) => log(service, line))
    })
  }

  child.on('exit', (code) => {
    if (shuttingDown) return
    log(service, `exited with code ${code}, stopping everything`)
    shutdown(code || 1)
  })

  children.push({ service, child })
}

function killTree(pid) {
  try {
    if (isWindows) {
      execSync(`taskkill /PID ${pid} /T /F`, { stdio: 'ignore' })
    } else {
      process.kill(-pid, 'SIGTERM')
    }
  } catch {
    // already gone
  }
}

// Gradle runs the app inside its daemon, so killing the wrapper's tree may not stop the server.
// Free the port as a fallback.
function killPort(port) {
  try {
    if (isWindows) {
      const output = execSync(`netstat -ano | findstr LISTENING | findstr :${port}`, { encoding: 'utf8' })
      const pids = new Set(
        output
          .split(/\r?\n/)
          .map((line) => line.trim().split(/\s+/))
          .filter((cols) => cols[1]?.endsWith(`:${port}`))
          .map((cols) => cols[4]),
      )
      pids.forEach((pid) => pid && pid !== '0' && killTree(pid))
    } else {
      execSync(`lsof -ti tcp:${port} -sTCP:LISTEN | xargs kill`, { stdio: 'ignore' })
    }
  } catch {
    // nothing listening
  }
}

function shutdown(exitCode = 0) {
  if (shuttingDown) return
  shuttingDown = true
  console.log('\nStopping backend and frontend...')
  for (const { service, child } of children) {
    killTree(child.pid)
    killPort(service.port)
  }
  process.exit(exitCode)
}

process.on('SIGINT', () => shutdown(0))
process.on('SIGTERM', () => shutdown(0))
process.on('SIGHUP', () => shutdown(0)) // terminal window closed

if (!existsSync(path.join(root, 'nomanualcodeui', 'node_modules'))) {
  console.log('Installing frontend dependencies...')
  execSync('npm install', { cwd: path.join(root, 'nomanualcodeui'), stdio: 'inherit' })
}

services.forEach(start)
console.log('Backend: http://localhost:8080  Frontend: http://localhost:5173  (Ctrl+C to stop both)')
