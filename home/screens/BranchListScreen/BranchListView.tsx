import { spacing } from '@expo/styleguide-native';
import { Divider, useExpoTheme, View } from 'expo-dev-client-components';
import * as React from 'react';
import { FlatList, ActivityIndicator, View as RNView } from 'react-native';
import InfiniteScrollView from 'react-native-infinite-scroll-view';

import { BranchListItem } from '../../components/BranchListItem';
import { BranchesForProjectQuery } from '../../graphql/types';

type BranchManifest = {
  name: string;
  id: string;
  latestUpdate: BranchesForProjectQuery['app']['byId']['updateBranches'][0]['updates'][0];
  sdkVersion: number | null;
};

type Props = {
  appId: string;
  data: BranchManifest[];
  loadMoreAsync: () => Promise<any>;
};

export function BranchListView(props: Props) {
  const [isReady, setReady] = React.useState(false);

  const theme = useExpoTheme();

  React.useEffect(() => {
    const _readyTimer = setTimeout(() => {
      setReady(true);
    }, 500);
    return () => {
      clearTimeout(_readyTimer);
    };
  }, []);

  if (!isReady) {
    return (
      <RNView
        style={{
          flex: 1,
          padding: 30,
          alignItems: 'center',
          backgroundColor: theme.background.screen,
        }}>
        <ActivityIndicator />
      </RNView>
    );
  }

  if (!props.data?.length) {
    return <RNView style={{ flex: 1, backgroundColor: theme.background.screen }} />;
  }

  return <BranchList {...props} />;
}

function BranchList({ data, appId, loadMoreAsync }: Props) {
  const [isLoadingMore, setLoadingMore] = React.useState(false);
  const isLoading = React.useRef<null | boolean>(false);
  const theme = useExpoTheme();

  const extractKey = React.useCallback((item: BranchManifest) => item.id, []);

  const handleLoadMoreAsync = async () => {
    if (isLoading.current) return;
    isLoading.current = true;
    setLoadingMore(true);

    try {
      await loadMoreAsync();
    } catch (e) {
      console.error(e);
    } finally {
      isLoading.current = false;
      setLoadingMore(false);
    }
  };

  const canLoadMore = () => {
    if (isLoadingMore) {
      return false;
    } else {
      return true;
    }
  };

  const renderItem = React.useCallback(
    ({ item: branch, index }: { item: BranchManifest; index: number }) => {
      return (
        <BranchListItem
          key={branch.id}
          appId={appId}
          name={branch.name}
          latestUpdate={branch.latestUpdate}
          first={index === 0}
          last={index === data.length - 1}
        />
      );
    },
    []
  );

  return (
    <View
      flex="1"
      style={{
        backgroundColor: theme.background.screen,
      }}>
      <FlatList
        data={data}
        keyExtractor={extractKey}
        renderItem={renderItem}
        // @ts-expect-error typescript cannot infer that props should include infinite-scroll-view props
        renderLoadingIndicator={() => <RNView />}
        renderScrollComponent={(props) => <InfiniteScrollView {...props} />}
        contentContainerStyle={{ padding: spacing[4] }}
        ItemSeparatorComponent={() => <Divider style={{ height: 1 }} />}
        canLoadMore={canLoadMore()}
        onLoadMoreAsync={handleLoadMoreAsync}
      />
    </View>
  );
}
