import { css } from '@emotion/react';
import { theme, typography } from '@expo/styleguide';
import NextLink from 'next/link';
import { NextRouter } from 'next/router';
import * as React from 'react';

import stripVersionFromPath from '~/common/stripVersionFromPath';
import { paragraph } from '~/components/base/typography';
import { NavigationRoute } from '~/types/common';

const STYLES_LINK = css`
  display: block;
  text-decoration: none;
`;

const STYLES_ACTIVE = css`
  ${paragraph}
  font-size: 15px;
  line-height: 140%;
  font-family: ${typography.fontFaces.medium};
  color: ${theme.link.default};
  position: relative;
  left: -7px;

  :visited {
    color: ${theme.link.default};
  }

  :hover {
    color: ${theme.link.default};
  }
`;

const STYLES_DEFAULT = css`
  ${paragraph}
  color: ${theme.text.default};
  line-height: 140%;
  transition: 50ms ease color;
  font-size: 15px;

  :visited {
    color: ${theme.text.default};
  }

  :hover {
    color: ${theme.link.default};
  }
`;

const STYLES_ACTIVE_CONTAINER = css`
  display: flex;
  margin-bottom: 12px;
`;

const STYLES_ACTIVE_BULLET = css`
  min-height: 6px;
  min-width: 6px;
  height: 6px;
  width: 6px;
  background-color: ${theme.link.default};
  border-radius: 4px;
  position: relative;
  left: -12px;
  top: 7px;
`;

type Props = {
  router: NextRouter;
  info: NavigationRoute;
};

export default class DocumentationSidebarLink extends React.Component<
  React.PropsWithChildren<Props>
> {
  componentDidMount() {
    // Consistent link behavior across dev server and static export
    // @ts-ignore
    global.__NEXT_DATA__.nextExport = true;
  }

  isSelected() {
    if (!this.props.router) {
      console.log('[debug] isSelected bailed out, no router', this.props);
      return false;
    }

    // Special case for root url
    if (this.props.info.name === 'Introduction') {
      const { asPath } = this.props.router;
      if (asPath.match(/\/versions\/[\w.]+\/$/) || asPath === '/versions/latest/') {
        return true;
      }
    }

    const linkUrl = stripVersionFromPath(this.props.info.as || this.props.info.href);
    if (
      linkUrl === stripVersionFromPath(this.props.router.pathname) ||
      linkUrl === stripVersionFromPath(this.props.router.asPath)
    ) {
      return true;
    }

    return false;
  }

  isHidden() {
    return this.props.info.hidden;
  }

  render() {
    if (this.isHidden()) {
      return null;
    }

    const customDataAttributes = this.isSelected()
      ? {
          'data-sidebar-anchor-selected': true,
        }
      : {};

    return (
      <div css={STYLES_ACTIVE_CONTAINER}>
        {this.isSelected() && <div css={STYLES_ACTIVE_BULLET} />}
        <NextLink
          href={this.props.info.href as string}
          as={this.props.info.as || this.props.info.href}
          passHref>
          <a
            {...customDataAttributes}
            css={[STYLES_LINK, this.isSelected() ? STYLES_ACTIVE : STYLES_DEFAULT]}>
            {this.props.children}
          </a>
        </NextLink>
      </div>
    );
  }
}
