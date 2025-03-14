import { getExpoHomeDirectory } from '@expo/config/build/getUserState';
import path from 'path';

import { getVersionsAsync, SDKVersion } from '../api/getVersions';
import { downloadAppAsync } from './downloadAppAsync';
import { CommandError } from './errors';
import { profile } from './profile';
import { createProgressBar } from './progress';

const debug = require('debug')('expo:utils:downloadExpoGo') as typeof console.log;

const platformSettings: Record<
  string,
  {
    shouldExtractResults: boolean;
    versionsKey: keyof SDKVersion;
    getFilePath: (filename: string) => string;
  }
> = {
  ios: {
    versionsKey: 'iosClientUrl',
    getFilePath: (filename) =>
      path.join(getExpoHomeDirectory(), 'ios-simulator-app-cache', `${filename}.app`),
    shouldExtractResults: true,
  },
  android: {
    versionsKey: 'androidClientUrl',
    getFilePath: (filename) =>
      path.join(getExpoHomeDirectory(), 'android-apk-cache', `${filename}.apk`),
    shouldExtractResults: false,
  },
};

/** Download the Expo Go app from the Expo servers (if only it was this easy for every app). */
export async function downloadExpoGoAsync(
  platform: keyof typeof platformSettings,
  {
    url,
    sdkVersion,
  }: {
    url?: string;
    sdkVersion?: string;
  }
): Promise<string> {
  const { getFilePath, versionsKey, shouldExtractResults } = platformSettings[platform];

  const bar = createProgressBar('Downloading the Expo Go app [:bar] :percent :etas', {
    width: 64,
    total: 100,
    clear: true,
    complete: '=',
    incomplete: ' ',
  });

  if (!url) {
    if (!sdkVersion) {
      throw new CommandError(
        `Unable to determine which Expo Go version to install (platform: ${platform})`
      );
    }
    const { sdkVersions: versions } = await getVersionsAsync();

    const version = versions[sdkVersion];
    if (!version) {
      throw new CommandError(
        `Unable to find a version of Expo Go for SDK ${sdkVersion} (platform: ${platform})`
      );
    }
    debug(`Installing Expo Go version for SDK ${sdkVersion} at URL: ${version[versionsKey]}`);
    url = version[versionsKey] as string;
  }

  const filename = path.parse(url).name;

  try {
    const outputPath = getFilePath(filename);
    debug(`Downloading Expo Go from "${url}" to "${outputPath}".`);
    debug(
      `The requested copy of Expo Go might already be cached in: "${getExpoHomeDirectory()}". You can disable the cache with EXPO_NO_CACHE=1`
    );
    await profile(downloadAppAsync)({
      url,
      // Save all encrypted cache data to `~/.expo/expo-go`
      cacheDirectory: 'expo-go',
      outputPath,
      extract: shouldExtractResults,
      onProgress({ progress }) {
        if (bar) {
          bar.tick(1, progress);
        }
      },
    });
    return outputPath;
  } finally {
    bar?.terminate();
  }
}
