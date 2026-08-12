const mode = process.env.NODE_ENV?.trim() || 'development'
const isDev = mode === 'development'

const config = {
  appId: isDev ? 'watch.zeroshiru.dev' : 'watch.zeroshiru',
  appName: isDev ? 'Shiru (Debug)' : 'Shiru',
  webDir: 'build',
  android: {
    buildOptions: {
      keystorePath: './zeroshiru.jks',
      keystorePassword: '',
      keystoreAlias: 'zeroshiru'
    },
    webContentsDebuggingEnabled: true
  },
  plugins: {
    SplashScreen: {
      launchShowDuration: 10_000,
      backgroundColor: '#191d21',
      androidSplashResourceName: 'splash_icon',
      androidScaleType: 'CENTER_CROP'
    },
    CapacitorHttp: {
      enabled: true
    },
    CapacitorNodeJS: {
      nodeDir: 'nodejs'
    },
    LocalNotifications: {
      sound: 'ic_notification.wav'
    },
    SystemBars: {
      insetsHandling: 'css',
      style: 'DARK'
    }
  },
  server: {
    cleartext: true
  }
}

if (isDev) config.server.url = 'http://localhost:5001/index.html'

module.exports = config