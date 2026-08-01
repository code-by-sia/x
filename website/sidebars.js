// @ts-check

// Ordered as a learning path: what Xi is, how to run it, the language itself,
// how to structure a program, then the domain features, and finally reference.
//
// Everything that ships in `std/` lives under "Standard library" — previously
// several of those pages (collections, events, web, query, data) sat loose at
// the sidebar root, which made it hard to tell language from library.

/** @type {import('@docusaurus/plugin-content-docs').SidebarsConfig} */
const sidebars = {
  docs: [
    'index',
    {
      type: 'category',
      label: 'Getting started',
      collapsed: false,
      items: ['getting-started', 'cli'],
    },
    {
      type: 'category',
      label: 'The language',
      collapsed: false,
      items: ['language-guide', 'error-handling', 'decisions'],
    },
    {
      type: 'category',
      label: 'Structuring a program',
      collapsed: false,
      items: ['dependency-injection', 'multi-file', 'config', 'testing'],
    },
    {
      type: 'category',
      label: 'State, events & concurrency',
      items: ['atoms', 'machines', 'interrupts', 'events', 'threading', 'memory'],
    },
    {
      type: 'category',
      label: 'Standard library',
      collapsed: false,
      items: [
        'stdlib',        // the index / API reference for every module
        'collections',
        'serialization',
        'query',
        'data',
        'web',
        'monitoring',
      ],
    },
    {
      type: 'category',
      label: 'Interop & targets',
      items: ['ffi', 'wasm', 'native-backend'],
    },
    {
      type: 'category',
      label: 'Reference',
      items: ['skill', 'internals'],
    },
  ],
};

module.exports = sidebars;
