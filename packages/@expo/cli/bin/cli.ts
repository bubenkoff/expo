#!/usr/bin/env node
import arg from 'arg';
import chalk from 'chalk';
import Debug from 'debug';
import { boolish } from 'getenv';

// Setup before requiring `debug`.
if (boolish('EXPO_DEBUG', false)) {
  Debug.enable('expo:*');
} else if (Debug.enabled('expo:')) {
  process.env.EXPO_DEBUG = '1';
}

const defaultCmd = 'start';

export type Command = (argv?: string[]) => void;

const commands: { [command: string]: () => Promise<Command> } = {
  // Add a new command here
  'run:ios': () => import('../src/run/ios').then((i) => i.expoRunIos),
  'run:android': () => import('../src/run/android').then((i) => i.expoRunAndroid),
  start: () => import('../src/start').then((i) => i.expoStart),
  prebuild: () => import('../src/prebuild').then((i) => i.expoPrebuild),
  config: () => import('../src/config').then((i) => i.expoConfig),
  export: () => import('../src/export').then((i) => i.expoExport),
  'export:web': () => import('../src/export/web').then((i) => i.expoExportWeb),

  // Auxiliary commands
  install: () => import('../src/install').then((i) => i.expoInstall),
  customize: () => import('../src/customize').then((i) => i.expoCustomize),

  // Auth
  login: () => import('../src/login').then((i) => i.expoLogin),
  logout: () => import('../src/logout').then((i) => i.expoLogout),
  register: () => import('../src/register').then((i) => i.expoRegister),
  whoami: () => import('../src/whoami').then((i) => i.expoWhoami),
};

const args = arg(
  {
    // Types
    '--version': Boolean,
    '--help': Boolean,
    // NOTE(EvanBacon): This is here to silence warnings from processes that
    // expect the global expo-cli.
    '--non-interactive': Boolean,

    // Aliases
    '-v': '--version',
    '-h': '--help',
  },
  {
    permissive: true,
  }
);

if (args['--version']) {
  // Version is added in the build script.
  console.log(process.env.__EXPO_VERSION);
  process.exit(0);
}

if (args['--non-interactive']) {
  console.warn(chalk.yellow`  {bold --non-interactive} is not supported, use {bold $CI=1} instead`);
}

// Check if we are running `npx expo <subcommand>` or `npx expo`
const isSubcommand = Boolean(commands[args._[0]]);

// Handle `--help` flag
if (!isSubcommand && args['--help']) {
  const {
    login,
    logout,
    whoami,
    register,
    start,
    install,
    export: _export,
    config,
    customize,
    prebuild,
    'run:ios': runIos,
    'run:android': runAndroid,
    ...others
  } = commands;

  console.log(chalk`
  {bold Usage}
    {dim $} npx expo <command>

  {bold Commands}
    ${Object.keys({ start, export: _export, ...others }).join(', ')}
    ${Object.keys({ 'run:ios': runIos, 'run:android': runAndroid, prebuild }).join(', ')}
    ${Object.keys({ install, customize, config }).join(', ')}
    {dim ${Object.keys({ login, logout, whoami, register }).join(', ')}}

  {bold Options}
    --version, -v   Version number
    --help, -h      Usage info

  For more info run a command with the {bold --help} flag
    {dim $} npx expo start --help
`);
  process.exit(0);
}

// NOTE(EvanBacon): Squat some directory names to help with migration,
// users can still use folders named "send" or "eject" by using the fully qualified `npx expo start ./send`.
if (!isSubcommand) {
  const migrationMap: Record<string, string> = {
    init: 'npx create-expo-app',
    eject: 'npx expo prebuild',
    web: 'npx expo start --web',
    'start:web': 'npx expo start --web',
    'build:ios': 'eas build -p ios',
    'build:android': 'eas build -p android',
    'client:install:ios': 'npx expo start --ios',
    'client:install:android': 'npx expo start --android',
    doctor: 'expo doctor',
    upgrade: 'expo upgrade',
    'customize:web': 'npx expo customize',

    publish: 'eas update',
    'publish:set': 'eas update',
    'publish:rollback': 'eas update',
    'publish:history': 'eas update',
    'publish:details': 'eas update',

    'build:web': 'npx expo export',

    'credentials:manager': `eas credentials`,
    'fetch:ios:certs': `eas credentials`,
    'fetch:android:keystore': `eas credentials`,
    'fetch:android:hashes': `eas credentials`,
    'fetch:android:upload-cert': `eas credentials`,
    'push:android:upload': `eas credentials`,
    'push:android:show': `eas credentials`,
    'push:android:clear': `eas credentials`,
    url: `eas build:list`,
    'url:ipa': `eas build:list`,
    'url:apk': `eas build:list`,
    webhooks: `eas webhook`,
    'webhooks:add': `eas webhook:create`,
    'webhooks:remove': `eas webhook:delete`,
    'webhooks:update': `eas webhook:update`,

    'build:status': `eas build:list`,
    'upload:android': `eas submit -p android`,
    'upload:ios': `eas submit -p ios`,
  };

  const subcommand = args._[0];
  if (subcommand in migrationMap) {
    const replacement = migrationMap[subcommand];
    console.log();
    console.log(
      chalk.yellow`  {gray $} {bold expo ${subcommand}} is not supported in the local CLI, please use {bold ${replacement}} instead`
    );
    console.log();
    process.exit(1);
  }
  const deprecated = ['send', 'client:ios'];
  if (deprecated.includes(subcommand)) {
    console.log();
    console.log(chalk.yellow`  {gray $} {bold expo ${subcommand}} is deprecated`);
    console.log();
    process.exit(1);
  }
}

const command = isSubcommand ? args._[0] : defaultCmd;
const commandArgs = isSubcommand ? args._.slice(1) : args._;

// Push the help flag to the subcommand args.
if (args['--help']) {
  commandArgs.push('--help');
}

// Install exit hooks
process.on('SIGINT', () => process.exit(0));
process.on('SIGTERM', () => process.exit(0));

commands[command]().then((exec) => exec(commandArgs));
