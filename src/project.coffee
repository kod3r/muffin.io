# The `project` is a singleton that takes charge of project settings,
# plugins and other global objects.

fs = require 'fs'
sysPath = require 'path'
_ = require './utils/_inflection'
CoffeeScript = require 'coffee-script'
Generator = require './PluginTypes/Generator'
Compiler = require './PluginTypes/Compiler'
Optimizer = require './PluginTypes/Optimizer'

class Project

  constructor: ->
    @clientConfig = {}
    @serverConfig = {}

    # These are used to facilitate module loading.
    @requireConfig = {}
    @packageDeps = {}

    # Load `config.json` in the project directory
    try
      @config = require sysPath.resolve('config.json')
      @parseConfig()
    catch e
      return

  # Retrieve directory settings from the config file
  parseConfig: ->
    @clientDir = sysPath.resolve(@config.clientDir ? 'client')
    @serverDir = sysPath.resolve(@config.serverDir ? 'server')
    @buildDir = sysPath.resolve(@config.buildDir ? 'public')

    @clientAssetsDir = sysPath.join(@clientDir, 'assets')
    @clientComponentsDir = sysPath.join(@clientDir, 'components')

    @jsDir = sysPath.join(@buildDir, 'javascripts')
    @tempBuildDir = sysPath.resolve('.tmp-build')

  # Load environment-specific settings.
  # `env` can be `development`, `production` or `test`.
  setEnv: (env) ->
    @clientConfig = {env}
    config = {}
    try config = require sysPath.join(@clientDir, 'config.json')
    for key, value of config
      if key in ['development', 'production', 'test']
        if key is env
          _.extend @clientConfig, value
      else
        @clientConfig[key] = value

    @serverConfig = {env}
    config = {}
    try config = require sysPath.join(@serverDir, 'config.json')
    for key, value of config
      if key in ['development', 'production', 'test']
        if key is env
          _.extend @serverConfig, value
      else
        @serverConfig[key] = value

    # Now that all the settings are loaded, we are ready to load plugins.
    @loadPlugins()

  # Load plugins
  loadPlugins: ->
    # There are three kinds of plugins: compilers, generators and optimizers.
    @plugins = {'compilers': [], 'generators': [], 'optimizers': []}

    # First we load all the mandatory plugins
    mandatoryPlugins = [
      'muffin-compiler-js'
      'muffin-compiler-html'
      'muffin-compiler-coffeescript'
      'muffin-compiler-appcache'
    ]
    @registerPlugin(name) for name in mandatoryPlugins

    # Then we load optional plugins listed in `config.json`
    @registerPlugin(name) for name in @config.plugins

  # Register a single plugin
  registerPlugin: (name) ->
    # Save the plugin for later use
    done = (plugin) =>
      switch plugin.type
        when 'compiler'
          @plugins['compilers'].push plugin
        when 'generator'
          @plugins['generators'].push plugin
        when 'optimizer'
          @plugins['optimizers'].push plugin

    # When we load a plugin, we pass in (env, callback) as the arguments.
    # `env` gives the plugin access to superclasses and project settings.
    pluginEnv = {Generator, Compiler, Optimizer, project: @, _}

    # First search in Muffin's built-in plugins folder
    pluginPath = sysPath.join(__dirname, "../plugins/#{name}")
    try return require(pluginPath)(pluginEnv, done)

    # Then search in the global `node_modules` folder
    pluginPath = sysPath.join(__dirname, "../../#{name}")
    try return require(pluginPath)(pluginEnv, done)

  # Build the require config from packages
  buildRequireConfig: ->
    _aliases = @clientConfig.aliases
    _scripts = []
    _exports = {}

    isDirectory = (path) ->
      stats = fs.statSync(path)
      stats.isDirectory()

    # iterate over the components dir and get module deps
    users = fs.readdirSync(@clientComponentsDir)
    for user in users
      userDir = sysPath.join(@clientComponentsDir, user)
      if isDirectory(userDir)
        projects = fs.readdirSync(userDir)
        for p in projects
          projectDir = sysPath.join(userDir, p)
          if isDirectory(projectDir)
            # parse component.json
            json = fs.readFileSync(sysPath.join(projectDir, 'component.json'))
            json = JSON.parse(json)
            repo = "#{user}/#{p}"

            # Strip the .js or .coffee suffix
            if json.main
              indexFile = json.main.replace(/\.coffee$/, '').replace(/\.js$/, '')
            else
              indexFile = 'index'

            indexPath = "components/#{repo}/#{indexFile}"
            _aliases[json.name] = _aliases[repo] = indexPath

            if json.type is 'script'
              _scripts.push indexPath

            if json.exports
              _exports[indexPath] = json.exports

            if json.dependencies
              @packageDeps[repo] = Object.keys(json.dependencies)

    @requireConfig = {aliases: _aliases, scripts: _scripts, exports: _exports}

  loadHtmlHelpers: ->
    # Underscore template settings
    _.templateSettings =
      evaluate    : /<\?([\s\S]+?)\?>/g,
      interpolate : /<\?=([\s\S]+?)\?>/g,
      escape      : /<\?-([\s\S]+?)\?>/g

    # Module loader source
    moduleLoaderSrc = fs.readFileSync(sysPath.join(__dirname, 'client/module-loader.coffee')).toString()
    moduleLoaderSrc = _.template(moduleLoaderSrc, {settings: @clientConfig})
    moduleLoaderSrc = CoffeeScript.compile(moduleLoaderSrc)

    liveReloadSrc = fs.readFileSync(sysPath.join(__dirname, 'client/live-reload.coffee')).toString()
    liveReloadSrc = _.template(liveReloadSrc, {settings: @clientConfig})
    liveReloadSrc = CoffeeScript.compile(liveReloadSrc)

    # Build require config
    requireConfig = @buildRequireConfig()

    # Retrieve the assetHost and cacheBuster settings from client config file.
    assetHost = @clientConfig.assetHost ? ''
    cacheBuster = if @clientConfig.cacheBuster then "?_#{(new Date()).getTime()}" else ''

    @htmlHelpers =
      link_tag: (link, attrs={}) ->
        "<link href='#{assetHost}#{link}#{cacheBuster}' #{("#{k}='#{v}'" for k, v of attrs).join(' ')}>"
      stylesheet_link_tag: (link, attrs={}) ->
        "<link rel='stylesheet' type='text/css' href='#{assetHost}#{link}#{cacheBuster}' #{("#{k}='#{v}'" for k, v of attrs).join(' ')}>"
      script_tag: (src, attrs={}) ->
        "<script src='#{assetHost}#{src}#{cacheBuster}' #{("#{k}='#{v}'" for k, v of attrs).join(' ')}></script>"
      image_tag: (src, attrs={}) ->
        "<img src='#{assetHost}#{src}#{cacheBuster}' #{("#{k}='#{v}'" for k, v of attrs).join(' ')}>"
      include_module_loader: ->
        """
        <script>#{moduleLoaderSrc}</script>
        <script>require.config(#{JSON.stringify(requireConfig)})</script>
        """
      include_live_reload: ->
        """
        <script>#{liveReloadSrc}</script>
        """

module.exports = new Project()
