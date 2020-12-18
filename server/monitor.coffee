# Adapted from the Spludo Framework.
# Copyright (c) 2009-2010 DracoBlue, http://dracoblue.net/
#
# and from https://github.com/pkrumins/node-tree-kill
# 
# Licensed under the terms of MIT License. For the full copyright and license
# information, please see the LICENSE file in the root folder.

Child_process = require('child_process')
Https = require 'https'
Fs = require 'fs'
Util = require 'util'
Path = require 'path'
Events = require 'events'
File = require './file'
Document = require './document'
Interface = require './interface'
{Sessions} = require './workflow'
Url = require 'url'
Chokidar = require 'chokidar'
_ = require '../general/chocodash' 
Chocokup = require '../general/chocokup' 
Debugate = require '../general/debugate' 

monitor_server = new class
    process: null
    compile_process: {}
    restarting: false
    appdir: null
    logging: yes
    config: null
    user: null
    group: null
    key:null
    cert:null
    server:null
    sep: if process.platform is 'win32' then '\\' else '/'
    dir:
        node_modules:if process.platform is 'win32' then '\\node_modules\\' else '/node_modules/'
        client:if process.platform is 'win32' then '\\client\\' else '/client/'
        general:if process.platform is 'win32' then '\\general\\' else '/general/'
        server:if process.platform is 'win32' then '\\server\\' else '/server/'
        'static':if process.platform is 'win32' then '\\static\\' else '/static/'
        acme:if process.platform is 'win32' then '\\acme\\' else '/acme/'

    "log": (msg) ->
        Debugate.log "Time:#{new Date().toISOString()}: " + msg if @logging

    "exit": ->
        this.log 'CHOCOLATEJS: terminate child process'
        this.killProcesses()
        check = =>
            # if child process exited we can also exit
            # otherwise we wait...
            unless @process? 
                this.log 'CHOCOLATEJS: exit'
                setTimeout (-> process.exit()), 100
                
        check()
        setInterval check, 100

    "restart": (signal) ->
        self = this
        
        @throttled_restart ?= _.throttle wait:1000, reset:on, ->
            @restarting = true
            self.log 'CHOCOLATEJS: Stopping server for restart'
            self.killProcesses(signal)
        
        @throttled_restart()

    "start": ->
        process.chdir __dirname + '/..'
        args = []
        for arg, i in process.argv when i>1
            kv = arg.split '='
            switch kv[0]
                when "--appdir" then @appdir = kv[1]
                when "--port" then @port = kv[1]
                when "--memory" then @memory = kv[1]
                when "--user" then @user = kv[1]
                when "--group" then @group = kv[1]
                else args.push kv[0] unless kv[1]?
        @appdir ?=  args[0]
        @port ?=  args[1]
        @memory ?=  args[2]
        @user ?=  args[3]
        @group ?=  args[4]
        @datadir = "#{(if not @appdir? or @appdir is '.' then '.' else  Path.relative process.cwd(), @appdir)}#{@sep}data"
        
        if @user? then process.setgid @group ? @user ; process.setuid @user ; process.env.HOME = @appdir ; process.env.USER = @user
        
        self = this

        @config = require('./config')(@datadir, reload:on).clone()
        if @config.letsencrypt?
            hostname = @config.letsencrypt.domains[0] if @config.letsencrypt.domains?
            @cert_suffix = "#{self.dir.acme}#{hostname}#{self.sep}fullchain.pem" if hostname?
        
        process.on 'uncaughtException', (err) ->
            console.error((err && err.stack) ? new Date() + '\n' + err.stack + '\n\n' : err);
            
        process.on 'SIGTERM', -> self.exit()

        this.log 'CHOCOLATEJS: Starting server'
        this.watchFiles()


        if @config.debug or @config.monitor?['interface']
            @key = @config.key
            @key ?= if @config.letsencrypt?.published is on then 'privkey.pem' else 'privatekey.pem'
            @cert = @config.cert
            @cert ?= if @config.letsencrypt?.published is on then 'fullchain.pem' else 'certificate.pem'

        args = []
        args.push @appdir if @appdir?
        args.push @port if @port?
        cmds = []
        cmds = ['--nodejs', "--max-old-space-size=#{@memory}"] if @memory?
        cmds = ['--nodejs', '--inspect'] if @config.debug
        cmds.push 'server/server.coffee'
        @process = Child_process.spawn("coffee#{if process.platform is 'win32' then '.cmd' else ''}", cmds.concat args)

        @process.stdout.addListener 'data', (data) ->
            process.stdout.write(data)

        @process.stderr.addListener 'data', (data) ->
            process.stderr.write(data)

        @process.addListener 'exit', (code) ->
            self.log 'CHOCOLATEJS: Child process exited: ' + code
            self.process = null

            if self.restarting
                self.unwatchFiles()
                self.start()
                self.restarting = false
        
        if @config.monitor?['interface']
            this.interface()

    "convertFile": _.throttle wait:500, reset:on, (file, file_path, file_ext, file_base, curdir) ->
        file_dest_name = file_path + file_base + if file_ext in ['.scss'] then '.css' else '.html'
        add_dest_file_to_git = not Fs.existsSync file_dest_name
        source = null; code = null; curent_code = null

        self = this
        _.flow (run) ->
            run (end) ->
                Fs.readFile file, (err, data) -> 
                    source = data.toString() unless err?
                    end()
            run (end) ->
                if source? and source isnt ""
                    try switch file_ext 
                        when '.scss' then code = require('node-sass').renderSync(data:source, includePaths:[Path.dirname(file), self.appdir + self.sep + 'client']).css
                        else code = new Chocokup.Panel(source).render(format:yes)
                    catch e then self.log "CHOCOLATEJS (convertFile): #{e}" ; 
                
                end()
            run (end) ->
                Fs.readFile file_dest_name, (err, data) -> 
                    curent_code = data.toString() unless err?
                    end()
            run ->
                if code? and code isnt "" and code isnt curent_code
                    Fs.writeFile file_dest_name, code, (err) ->
                        unless err? and add_dest_file_to_git 
                            Child_process.exec 'git add ' + file_dest_name, cwd:curdir if add_dest_file_to_git
        
    "watchFiles": ->
        self = this
        
        appdir = if @appdir? then @appdir else '.'
        sysdir = Path.resolve __dirname, '..' 
        
        filter = (path) ->
            dotdot_re = if process.platform is 'win32' then /^\.[^\.\\]+/ else /^\.[^\.\/]+/
            if path.search(dotdot_re) isnt -1 then return yes
            if path.search(/(^|[\/\\])\../) isnt -1 then return yes # dot files
            if path.search(/[\/\\]node_modules[\/\\]/g) isnt -1 then return yes # node_module files
            for folder in ['static']
                if path is folder then return yes
            try stats = Fs.statSync path catch then return yes
            if stats.isDirectory() then return no
            suffixes = ['.js', '.coffee', '.chocokup', '.ck', '.scss', '.config.json']
            suffixes.push self.cert_suffix if self.cert_suffix?
            for suffix in suffixes
                if path.substr(path.length - suffix.length, suffix.length) is suffix then return no
            return yes

        on_add = (file) -> on_event 'add', file
        on_change = (file) -> on_event 'change', file           
        on_event = (event, file) ->
            return if self.restarting
            
            should_restart = if Path.extname(file) in ['.chocokup', '.ck', '.scss'] then no else yes
            
            if File.hasWriteAccess appdir
            
                build = (file, curdir) ->
                    static_lib_dirname = curdir + "#{self.dir.static}lib"
                    file_ext = Path.extname file
                    file_base = Path.basename file, file_ext
                    file_rel_path = Path.dirname(file).substr folder.length for folder in [curdir + self.dir.client, curdir + self.dir.general] when file.indexOf(folder) is 0
                    file_path = static_lib_dirname + self.sep + (if file_rel_path isnt '' then file_rel_path + self.sep else '')
                    File.ensurePathExists file_path
                    file_js_name = file_path + file_base + '.js'
                    add_js_file_to_git = not Fs.existsSync file_js_name
                    switch file_ext
                        when '.coffee' 
                            command = "coffee#{if process.platform is 'win32' then '.cmd' else ''}"
                            params = ['-c', '-o', file_path, file]
                        when '.js'
                            command = if process.platform is 'win32' then "copy" else "cp"
                            params = [file, file_js_name]
                        else
                            if file_ext in ['.chocokup', '.ck', '.scss'] and file.indexOf(curdir + self.dir.client) is 0
                                self.convertFile file, file_path, file_ext, file_base, curdir
                            command = param = undefined

                    bundles = self.config.build?.bundles ? []
                    bundles.push
                        filename: 'locco.js'
                        prefix: 'locco'
                        known_files: {
                            'locco/intention.js'
                            'locco/data.js'
                            'locco/action.js'
                            'locco/document.js'
                            'locco/workflow.js'
                            'locco/interface.js'
                            'locco/actor.js'
                            'locco/reserve.js'
                            'locco/prototype.js'
                        }
                        with_modules: on
                        
                    build_lib_package = (bundle) ->
                        bundle_file = ''

                        put = (pathname) ->
                            try
                                file_content = Fs.readFileSync static_lib_dirname + self.sep + pathname
                                
                                bundle_file += if bundle.with_modules
                                    """
                                    if (typeof window !== "undefined" && window !== null) { window.previousExports = window.exports; window.exports = {} };
                                    #{file_content}
                                    if (typeof window !== "undefined" && window !== null) { window.modules['#{pathname.replace ".js", ""}'] = window.exports; window.exports = window.previousExports };
                                    
                                    
                                    """
                                else 
                                    """
                                    #{file_content}
                                    
                                    
                                    """

                        sort = (a,b) ->
                            name = (path) ->
                                if (i = path.lastIndexOf '.') >= 0 then path[0...i] else path
                            if name(a) > name(b) then 1 else if name(a) < name(b) then -1 else 0
                        
                        
                        files = File.readDirDownSync static_lib_dirname
                        files = (file.substr(static_lib_dirname.length + 1) for file in files)
                        
                        for own filename of bundle.known_files then put filename
                        for filename in files.sort(sort) when bundle.known_files[filename] is undefined and filename.indexOf(bundle.prefix) is 0 and filename.indexOf('.spec') is -1 and filename isnt bundle.filename then put filename
                        
                        Fs.writeFileSync static_lib_dirname + self.sep + bundle.filename, bundle_file   
                    
                    if command? then do (file, file_base, file_js_name, add_js_file_to_git) ->
                        self.compile_process[file] = Child_process.spawn command, params, cwd:curdir
                        self.compile_process[file].addListener 'exit', (code) ->
                            Child_process.exec 'git add ' + file_js_name, cwd:curdir if add_js_file_to_git
                            
                            for bundle in bundles
                                file_rel_name = file_rel_path + (if file_rel_path is '' then '' else self.sep) + file_base + file_ext
                                if file_rel_name.indexOf(bundle.prefix) is 0 and file_base.indexOf('.spec') is -1
                                    build_lib_package(bundle)
                                    
                            delete self.compile_process[file]
            
                file = appdir + self.sep + file if appdir is '.'
                if (file.indexOf(appdir + self.dir.client) is 0 or file.indexOf(appdir + self.dir.general) is 0) then build file, appdir
                if (file.indexOf(sysdir + self.dir.client) is 0 or file.indexOf(sysdir + self.dir.general) is 0) then build file, sysdir

                if self.config.extensions? then for extension of self.config.extensions
                    if (file.indexOf(appdir + "#{self.dir.node_modules}#{extension}#{self.dir.client}") is 0 or file.indexOf(appdir + "#{self.dir.node_modules}#{extension}#{self.dir.general}") is 0) then build file, appdir + "#{self.dir.node_modules}#{extension}"
                        

            self.log "CHOCOLATEJS: #{if should_restart then 'Restarting because of' else 'Non restarting with'} " + event + ' file at ' + file
            
            setTimeout (-> self.restart() if should_restart), if process.platform is 'win32' then 100 else 10

        @watcher = Chokidar.watch appdir, ignored: filter, persistent: yes, ignoreInitial:yes
        @watcher.on 'add', on_add
        @watcher.on 'change', on_change

    "unwatchFiles": ->
        @watcher.close()

    "killAll": (tree, signal, callback) ->
        killed = {}
        try
            for pid of tree
                for pidpid in tree[pid]
                    if !killed[pidpid]
                        this.killPid pidpid, signal
                        killed[pidpid] = 1
                    return
                if !killed[pid]
                    this.killPid pid, signal
                    killed[pid] = 1
                return
        catch err
            if callback?
                return callback(err)
            else
                throw err
        if callback?
            return callback()
        return
    
    "killPid": (pid, signal) ->
        try
            this.log "kill #{signal ? ''} #{pid}"
            
            process.kill parseInt(pid, 10), signal
        catch err
            if err.code != 'ESRCH'
                throw err
        return
    
    "buildProcessTree": (parentPid, tree, pidsToProcess, spawnChildProcessesList, cb) ->
        ps = spawnChildProcessesList(parentPid)
        allData = ''
        ps.stdout.on 'data', (data) ->
            data = data.toString('ascii')
            allData += data
            return
    
        ps.on 'close', (code) =>
            delete pidsToProcess[parentPid]
            if code != 0
                # no more parent processes
                if (o for o of pidsToProcess).length == 0
                    cb()
                return
            for pid in allData.match(/\d+/g)
                pid = parseInt(pid, 10)
                tree[parentPid].push pid
                tree[pid] = []
                pidsToProcess[pid] = 1
                this.buildProcessTree pid, tree, pidsToProcess, spawnChildProcessesList, cb
                return
            return
    
        return
    
    "killProcesses": (signal) ->
        @process.kill 'SIGINT' if @process? and process.platform is 'win32'
        this.kill(@process.pid, signal) if @process?
        this.kill(@debug_process.pid, signal) if @debug_process?
        
    "kill": (pid, signal, callback) ->
        tree = {}
        pidsToProcess = {}
        tree[pid] = []
        pidsToProcess[pid] = 1
        switch process.platform
            when 'win32'
                Child_process.exec 'taskkill /pid ' + pid + ' /T /F', callback
            when 'darwin'
                this.buildProcessTree pid, tree, pidsToProcess, ((parentPid) ->
                    Child_process.spawn 'pgrep', [
                        '-P'
                        parentPid
                    ]
                ), =>
                    this.killAll tree, signal, callback
                    return
            else
                # Linux
                this.buildProcessTree pid, tree, pidsToProcess, ((parentPid) ->
                    Child_process.spawn 'ps', [
                        '-o'
                        'pid'
                        '--no-headers'
                        '--ppid'
                        parentPid
                    ]
                ), =>
                    this.killAll tree, signal, callback
                    return
                break
        return
    
    "interface": ->
        unless @server? or not @config.monitor?['interface']
            Document.datadir = @datadir
            cache = new Document.Cache async:off, filename: 'document-monitor.cache'
            sessions = new Sessions cache
                
            options = do =>
                dir = @datadir + if @config.letsencrypt?.published is on then '/acme/' + @config.letsencrypt.domains[0] else ''
                option = 
                    key: Fs.readFileSync dir + '/' + @key
                    cert: Fs.readFileSync dir + '/' + @cert
                [option]
                
            @server = Https.createServer.apply Https, options.concat (request, response) =>
                session = sessions.get(request)

                menu_kup = ->
                    form method:"get", ->
                        if @bin?.process? then div "process.pid: " + @bin.process.pid
                        if @bin?.debug_process? then div "debug_process.pid: " + @bin.debug_process.pid
                        if @bin?.process? or @bin?.debug_process? then div '&nbsp;'
                        input name:"action", type:"submit", value:"restart"

                restarted_kup = ->
                    form method:"get", ->
                        div 'Restarted'
                        div '&nbsp;'
                        div ->
                            input type:"submit", value:"OK"

                respond = (produced) ->
                    body = ""
                
                    if produced instanceof Chocokup
                        try body = produced.render()
                    else
                        body = produced
                        
                    result =
                        status: '200'
                        headers: {}
                        body: body
                        
                    result.headers['Set-Cookie'] = 'bsid=' + session.id + ';path=/;secure;httponly;expires=' + session.expires.toUTCString()
                    response.writeHead result.status, result.headers
                    response.end result.body
                
                url = Url.parse request.url
                if url.query is 'register_key'
                    produced = Interface.register_key {request, session}
                    
                    if produced instanceof Events.EventEmitter
                        produced.on 'end', => 
                            respond new Chocokup.Document 'Monitor', {kups:{key:menu_kup}, bin:{process:@process, debug_process:@debug_process}}, Chocokup.Kups.Tablet
                    else
                        respond produced
                else if url.query is 'action=restart'
                    respond if @config.sofkey of session.keys
                        do =>
                            this.restart('SIGKILL')
                            new Chocokup.Document 'Monitor', kups:{key:restarted_kup}, Chocokup.Kups.Tablet
                    else ''
                    
                else
                    respond if @config.sofkey of session.keys 
                        new Chocokup.Document 'Monitor', {kups:{key:menu_kup}, bin:{process:@process, debug_process:@debug_process}}, Chocokup.Kups.Tablet
                    else ''
                
    
            port_https = parseInt(@port ? @config.port_https ? @config.port ? 8026)
            @server.listen port_https + 2

        'Monitor Interface'

if process.argv[1] is __filename
    monitor_server.start()

