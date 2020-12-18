# Here is the Interface service of the Chocolate system.
# As all non-intentional services, it resides in the *system* sub-section of the *Chocolate* section.

# It manages the exchanges the Chocolate server *world*
# by providing an **exchange** service that can receive a request and produce a response.

# It requires **Node.js events** to communicate with asynchronous functions
Events = require 'events'
Path = require 'path'
Fs = require 'fs'
Crypto = require 'crypto'
File = require './file'
Formidable = require 'formidable'
_ = require '../general/chocodash'
Chocokup = require '../general/chocokup'
Chocodown = require '../general/chocodown'
Highlight = require '../general/highlight'
Interface = require '../general/locco/interface'

#### Cook
# `cook` serves a cookies object containing cookies from the sent request
exports.cook = (request) ->
    cookies = {}
    (cookie_pair = http_cookie.split '=' ; cookies[cookie_pair[0].trim()] = cookie_pair[1].trim()) for http_cookie in http_cookies.split ';' if (http_cookies = request.headers['cookie'])?
    cookies

#### Exchange
# `exchange` operates the interface
exports.exchange = (bin, send) ->
    {space, workflow, so, what, how, where, region, params, sysdir, appdir, datadir, backdoor_key, request, response, session, websocket, websockets} = bin

    config = require('./config')(datadir)
    where = where.replace(/\.\.[\/]*/g, '')
    
    console_ = 
        log: -> 
            console.log.apply console, arguments
            try websocket?.send JSON.stringify console:log:(if arguments.length is 1 then arguments[0] else arguments)

    context = {space, workflow, request, response, region, where, what, params, arguments:[], websocket, websockets, session, sysdir, appdir, datadir, config, console:console_}

    config = config.clone()
    
    # `respond` will send the computed result as an Http Response.
    respond = (result, as = how) ->
        return if result instanceof Interface.Reaction and result.piped
        
        type = 'text'
        status = 200
        subtype = switch as
            when 'web', 'edit', 'help' then 'html'
            when 'manifest' then 'cache-manifest'
            when 'pwa_worker' then 'javascript'
            else 'plain'
        
        unless as is 'raw'
            switch request.headers['accept']?.split(',')[0] 
                when 'application/json' then as = 'json'
                when 'application/json-late' then as = 'json-late'
        
        response_headers = { "Content-Type":"#{type}/#{subtype}; charset=utf-8" }
        
        switch as
            when 'manifest', 'pwa_worker'
                response_headers['Cache-Control'] = 'max-age=0'
                response_headers['Expires'] = new Date().toUTCString()
                
            when 'raw', 'json', 'json-late'
                if result instanceof Interface.Reaction then delete result.props
                unless as is 'raw' and Object.prototype.toString.call(result) is '[object String]'
                    result = if as is 'json-late' then _.stringify(result) else JSON.stringify(result)
        
            when 'web', 'edit', 'help'
                # render if instance of Chocokup
                
                if result instanceof Interface.Reaction
                    if result.redirect
                        status = 303
                        response_headers['Location'] = result.redirect
                        result = ''
                    else
                        result = result.bin ? ''
                
                if result instanceof Chocokup
                    try
                        result = result.render { backdoor_key }
                    catch error
                        return has500 error
                
                
                # Quirks mode in ie6
                if /msie 6/i.test request.headers['user-agent']
                    result = '<?xml version="1.0" encoding="iso-8859-1"?>\n' + result
                    
                # Defaults to Unicode
                unless request.headers['x-requested-with'] is 'XMLHttpRequest'
                    if result?.indexOf?('</head>') > 0
                        result = result.replace('</head>', '<meta http-equiv="content-type" content="text/html; charset=utf-8" /></head>')
                    else if result?.indexOf?('<body') > 0
                        result = result.replace('<body', '<head><meta http-equiv="content-type" content="text/html; charset=utf-8" /></head><body')
                    else
                        result = '<html><head><meta http-equiv="content-type" content="text/html; charset=utf-8" /></head><body>' + result + '</body></html>'
        
        send {status, headers:response_headers, body:result}
        
    # `has500` will send an HTTP 500 error
    has500 = (error) ->
        if error?
            if config.displayErrors
                source = if (info = error.source)? then "Error in Module:" + info.module + ", with Function :" + info.method + '\n' else ''
                line = if (info = error.location)? then "Coffeescript error at line:" + info.first_line + ", column:" + info.first_column + '\n' else ''
                send status : 500, headers : {"Content-Type": "text/plain"}, body : source + line + (error.stack ? error.toString()) + "\n"
            else
                send status : 500, headers : {"Content-Type": "text/plain"}, body : "\n"
            true
        else
            false
    
    # `hasSofkey` checks if requestor has the system sofkey which gives full rights access
    hasSofkey = ->
        hasKeypass = config.keypass is on and File.hasWriteAccess(appdir) is no
        hashed_backdoor_key = if backdoor_key isnt '' then Crypto.createHash('sha256').update(backdoor_key).digest('hex') else ''
        if config.sofkey in [hashed_backdoor_key, backdoor_key] or config.sofkey of session.keys or hasKeypass then true else false         

    # `getMethodInfo` retrieve a method and its parameters from a required module
    getMethodInfo = ({required, action, instanciate}) ->
        try
            self = klass = property = undefined
            method = node_module = require required
            
            if action?
                if node_module?.prototype?
                    method = method[name] for name in ('prototype.' + action).split('.') when method?
                    if method?
                        self = null ; klass = node_module ; property = name
                        if instanciate is on
                            self = new klass 
                            self.hydrate?.call self, args
                
                if node_module? and method is node_module or not method?
                    method ?= node_module
                    method = method[name] for name in action.split('.') when method?
            
            if action? and method instanceof Function
                infos = method.toString().match(/function(\s+\w*)*\s*\((.*?)\)/)
                args = infos[2].split(/\s*,\s*/) if infos?
            else if method instanceof Interface
                    self = method
                    method = method.submit
                    args = ['{__}']
            else throw new Error("Can't find '#{action}' in #{required}") 

                
            {method, args, self, klass, property}
        catch error
            error.source = module:required, method:action
            {method:undefined, args:undefined, self:undefined, klass:undefined, property:undefined, error}
        
    # `respondStatic` will send an HTTP response
    respondStatic = (status, headers, body) ->
        send { status, headers, body }
        
    # `exchangeStatic` is an interface with static web files
    exchangeStatic = () ->
        # Asking for a *static* resource (image, css, javascript...)
        if so is 'go'
            returns_empty = ->
                respondStatic 200, {}, ''
        
            returns = (required) ->
                extension = Path.extname where
                
                Fs.stat required, (error, stats) ->
                    return if has500 error
                    
                    headers =
                        'Date' : (new Date()).toUTCString()
                        'Etag' : [stats.ino, stats.size, Date.parse(stats.mtime)].join '-'
                        'Last-Modified' : (new Date(stats.mtime)).toUTCString()
                        'Cache-Control' : 'max-age=0'
                        'Expires' : new Date().toUTCString()
                    
                    if Date.parse(stats.mtime) <= Date.parse(request.headers['if-modified-since']) or request.headers['if-none-match'] is headers['Etag']
                        return respondStatic 304, headers
                    else
                        Fs.readFile required, null, (error, file) ->  
                            return if has500 error
                            
                            headers["Content-Type"] = switch extension 
                                when '.css' then  "text/css"
                                when '.js' then  "text/javascript"
                                when '.manifest' then "text/cache-manifest"
                                when '.ttf' then "font/ttf"
                                when '.html', '.md', '.markdown', '.cd', '.chocodown', '.ck', '.chocokup' then "text/html"
                                when '.pdf' then  "application/pdf"
                                when '.gif' then  "image/gif"
                                when '.png' then  "image/png"
                                when '.jpg', '.jpeg' then  "image/jpeg"
                            
                            respondStatic 200, headers, switch extension
                                when '.md', '.markdown', '.cd', '.chocodown', '.ck', '.chocokup'
                                    try
                                        if extension in ['.ck', '.chocokup']
                                            try html = new Chocodown.Chocokup.Panel(file.toString()).render() catch e then html = e.message
                                        else 
                                            html = new Chocodown.converter().makeHtml file.toString()
                                        if html.indexOf('<body') < 0 then html = '<html><head><meta http-equiv="content-type" content="text/html; charset=utf-8" /></head><body>' + html + '</body></html>' else html
                                    catch error
                                        'Error loading ' + where + ': ' + error
                                else file
            
            dirs = []
            # check in appdir
            dirs.push dir:(appdir ? '.') + '/'
            # check in extensions dirs
            if config.extensions? then for extension, mounting_point of config.extensions
                dirs.push {dir:(appdir ? '.') + "/node_modules/#{extension}/", mounting_point}
            # check in sysdir
            dirs.push dir:__dirname + '/../'
            
            for {dir, mounting_point} in dirs
                required = Path.resolve dir + (unless mounting_point? and mounting_point isnt '' then where else where.replace(mounting_point + '/', ''))
                if where.indexOf('static/' + (unless mounting_point? then '' else mounting_point)) is 0
                    if Fs.existsSync required then returns required ; return
            returns_empty()
            
    # `canExchange` check if current user has rights to operate exchange
    canExchange = () ->
        return hasSofkey() or (so is 'go' and where is 'ping') or (where is 'server/interface' and so is 'do' and what in ['register_key', 'forget_key'])
    
    # `exchangeSystem` is an interface with system files
    exchangeSystem = () ->
        # When authorized to access system resource -- 
        if canExchange() then exchangeClassic() else respond ''
    
    # `canExchangeClassic` checks if a file can be required at the specified path
    # so that a classic exchange can occur
    canExchangeClassic = (path) ->
        result =
            required: '../' + (if region is 'system' or appdir is '.' then '' else appdir + '/' ) + path
            found: yes
            
        return result if hasSofkey() and so is 'move'
        try require.resolve result.required
        catch error
            result.found = no
            if config.extensions? then for extension, mounting_point of config.extensions
                if (path.indexOf(mounting_point) is 0) or (path.indexOf('client/' + mounting_point) is 0) or (path.indexOf('general/' + mounting_point) is 0) or (path.indexOf('server/' + mounting_point) is 0)
                    result.required = '../' + (if appdir is '.' then '' else appdir + '/' ) + "node_modules/#{extension}/" + (if mounting_point is '' then path else path.replace(mounting_point + '/', ''))
                    try require.resolve result.required
                    catch error then continue
                    result.found = yes
                    result.extension = extension
                    break
        result

    # `exchangeClassic` is an interface with classic files (coffeescript or javascript)
    exchangeClassic = (required, extension) ->
        required ?= '../' + (if region is 'system' or appdir is '.' then '' else appdir + '/' ) + where
        #__ = if region is 'system' or appdir is '.' then undefined else context
        __ = context
        
        what_is_public = no
        is_classic_web_request = do ->
            return no if request.headers['x-requested-with'] is 'XMLHttpRequest'
            return yes if so is 'do' and how is 'web'
            return yes if so is 'go' and how is 'web' and where isnt 'ping'
            no

        switch so
            # if so is 'do' and what is public then authorize access  
            when 'do'
                {method, args, self, klass, property, error} = getMethodInfo { required, action:what }
                return if has500 error
                if method? and region isnt 'secure'
                    what_is_public = yes
    
            # if so is 'go' and where has a public interface then do use interface
            when 'go' 
                if how is 'web' and where isnt 'ping'
                    {method, args, self, klass, property, error} = getMethodInfo { required }
                    unless error
                        if method? then so = 'do' ; what = undefined ; what_is_public = yes
                    else
                        {method, args, self, klass, property, error} = getMethodInfo { required, action:'interface' }
                        return if has500 error
                        if method? # TODO - should implement security checking
                            so = 'do' ; what = 'interface'

        unless (so is 'do' and (what is 'interface' or what_is_public)) or canExchange() then respond ''; return

        switch so
            # Take care of the `go` action
            when 'go'
                # Answer to ping request
                if where is 'ping'
                    respond '{"status":"Ok"}'
                    return
                        
                # Get the system resource and check how to return it
                resource_path = require.resolve required

                switch how
                    # When `How` is 'web' or 'edit'
                    when 'web', 'edit'
                        File.access(where, backdoor_key, __).on 'end', (html) ->
                            respond html.error ? html
                    # when `How` is 'raw'
                    when 'raw', 'manifest', 'pwa_worker'
                        # Read the file and returns it
                        Fs.readFile resource_path, (err, data) ->
                            respond data.toString()

                    # when `How` is 'help'
                    when 'help'
                        # Ask **Doccolate** to generate a help page and returns it
                        Fs.readFile resource_path, (err, data) ->
                            respond require('../general/doccolate').generate resource_path, data.toString()
        
                    # when `How` is unknown
                    else
                        # Returns an error message
                        respond "Don't know how to respond as '" + how + "'"
                            
            # Take care of the `move` action
            when 'move'
                respondOnMoveFile = (count) ->
                    return respond '' if where is '' or count is 0
                    
                    results = []
                    for index in [0...count ? 1]
                        do ->
                            filename = File.setFilenameSuffix where, if index > 0 then "_#{index}" else ''
                            File.getModifiedDate(filename, __).on 'end', (modifiedDate) ->
                                results.push {filename, modifiedDate} if modifiedDate?
                                respond JSON.stringify results

                # Check if the `what` is empty
                if what is '' 
                    # If empty, take the input content from the POST data 
                    if request.method is 'POST'
                        content_type = request.headers['content-type']?.split(';')[0]
                        switch content_type
                            when 'multipart/form-data'
                                form = new Formidable.IncomingForm()
                                form.keepExtensions = yes
                                form.parse request, (err, fields, files) ->
                                    count = sent = received = 0
                                    errs = []
                                    count += 1 for name, file of files
                                    for name, file of files
                                        from = if __?.appdir? then Path.relative __.appdir, file.path else file.path
                                        if Path.extname(from) is '' 
                                            Fs.renameSync from, from = from + '.tmp'
                                        to = unless err? then where else ''
                                        event = File.moveFile from, File.setFilenameSuffix(to, if sent > 0 then "_#{sent}" else ''), __
                                        event.on 'end', (err) ->
                                            received += 1
                                            errs.push err if err?
                                            if received is count
                                                if errs.length > 0 then respond errs.join('\n') else respondOnMoveFile count
                                        sent += 1
                            else
                                source = chunks:[], length:0
                                request.on 'data', (chunk) ->
                                    source.chunks.push chunk
                                    source.length += chunk.length
                                    # test
                                request.on 'end', () ->          
                                    # When all POST data received, save new version
                                    File.writeToFile(where, Buffer.concat(source.chunks, source.length), __).on 'end', (err) ->
                                        if err? then respond err.toString() else respondOnMoveFile()
                    # If no POST date, create the `where` file with content from first parameter
                    else
                        File.writeToFile(where, params._0, __).on 'end', (err) ->
                            if err? then respond err.toString() else respondOnMoveFile()
                # If specified, move the `what` content to the `where` content
                else
                    File.moveFile(what, where, __).on 'end', (err) ->
                        if err? then respond err.toString() else respondOnMoveFile()
                            
            # Take care of the `eval` and `do` actions
            when 'do', 'eval'
                if so is 'eval'
                    args = [(if how is 'raw' then 'json' else 'html'), Path.resolve(__dirname + '/' + required), context]
                    required = '../general/specolate'
                    action = 'inspect'
                    node_module = require required 
                    method = node_module[action]
                else if so is 'do'
                    {method, args:expected_args, self, klass, property, error} = getMethodInfo { required, action:what, instanciate:on }
                    return if has500 error
                    if '__' in expected_args then params['__'] = context
                    args = []
                    
                    if is_classic_web_request and region is 'app' and config.masterInterfaces?
                        for masterInterface in config.masterInterfaces
                            doMasterInterface = no
                            if _.type(masterInterface.directory) is _.Type.Array
                                for directory in masterInterface.directory
                                    if where.indexOf(directory + '/') is 0 then doMasterInterface = yes ; break
                            else if masterInterface.directory? is false or masterInterface.directory is '' or where.indexOf(masterInterface.directory + '/') is 0 then doMasterInterface = yes
                            
                            if doMasterInterface and masterInterface.exclude?
                                for exclusion in masterInterface.exclude
                                    if where.indexOf(exclusion) is 0
                                        doMasterInterface = no
                                        break
                                
                            if doMasterInterface
                                if self instanceof Interface 
                                    params[masterInterface.prop] = self
                                else
                                    self_isnt_interface = true
                                    masterMethod = method
                                    params[masterInterface.prop] = new Interface.Web.Html
                                        use: -> {masterMethod}
                                        render: -> 
                                            text @props.masterMethod.apply undefined, @props.__.arguments
                                
                                self = require('../' + (if region is 'system' or appdir is '.' then '' else appdir + '/' ) + (if masterInterface.extension? then "node_modules/#{masterInterface.extension}/" else '') + masterInterface.where)[masterInterface.what]
                                self.embedded = params[masterInterface.prop]
                                method = self.submit
        
                    if expected_args[0] is '{__}' or self_isnt_interface
                        bin = {__:context}
                        bin[k] = v for k, v of params when k isnt '__'
                        args.push bin

                    args_index = 0
                    for arg_name in expected_args
                        context.arguments.push if params[arg_name] isnt undefined then params[arg_name] else params[ '__' + args_index++ ]
                    while args_index >= 0
                       if params['__' + args_index] is undefined then args_index = -1
                       else context.arguments.push params[ '__' + args_index++ ]

                    if expected_args[0] isnt '{__}'
                        args.push(arg) for arg in context.arguments

                produced = method.apply self, args

                if produced instanceof _.Publisher
                    produced.subscribe (answer) -> respond answer
                else if produced instanceof Events.EventEmitter
                    produced.on 'end', (answer) -> respond answer
                else respond produced
            else
                respond ''
            
    
    # `exchangeSimple` is an interface with intentional entities.
    # However, if a file can be required at the specified path, a classic exchange will occur
    exchangeSimple = () ->
        path = if where is '' and so isnt 'move' then where = 'default' else where

        result = canExchangeClassic path
        if result.found
            where = path
            try exchangeClassic(result.required, result.extension) catch err then hasSofkey() and has500(err) or respond ''
        else if region is 'app' and config.defaultExchange?
            old_params = params
            params_ = __0:where, __1:what
            index = 2 ; for k,v of params then params_['__' + index++] = v
            {extension, where, what, params} = _.clone {}, config.defaultExchange
            if extension? then where = "node_modules/#{extension}/#{where}"
            so = 'do' if what?
            what ?= ''
            if params? then for k,v of params then params[k] = (if _.type(v) is _.Type.Array then (if v.length is 1 then params_["__#{v[0]}"] else (params_["__#{i}"] for i in v)) else v)
            params ?= old_params
            exchangeClassic()
        else
            switch so
                when 'do'
                    produced = ''
                when 'move'
                    produced = ''
                when 'eval'
                    produced = ''
                when 'go'
                    # tranlate url query to Reserve query
                    produced = where
                    
            respond produced                             

    # To log requests...
    # require('../general/debugate').log '-> in ' + region + ' ' + so + ' ' + what + ' at ' + where + ' as ' + how + ' with ' + (k + ':' + v for k,v of params).join(' ')

    switch region
        when 'static' then exchangeStatic()
        when 'system' then exchangeSystem()
        else exchangeSimple()    

#### Key registration
# `registerKey` provides a UI to register a system key in browser session cache
exports.register_key = (__) ->
    enter_kup = ->
        form method:"post", ->
            text "Enter your Key : "
            input name:"key", type:"password"
            
    entered_kup = ->
        text 'Key registered'

    if __.request.method isnt 'POST'
        new Chocokup.Document 'Key registration', kups:{key:enter_kup}, Chocokup.Kups.Tablet

    else
        event = new Events.EventEmitter

        source = ''
        __.request.on 'data', (chunk) ->
            source += chunk
        __.request.on 'end', () ->
            fields = require('querystring').parse source

            __.session.addKey Crypto.createHash('sha256').update(fields.key).digest('hex')
            
            event.emit 'end', new Chocokup.Document 'Key registration', kups:{key:entered_kup}, Chocokup.Kups.Tablet

        event

# `forgetKey` provides a UI to clear keys from browser session cache
exports.forget_keys = (__) ->
    forget_kup = ->
        form method:"post", ->
            input name:"action", type:"submit", value:"Logoff"

    forgeted_kup = ->
        text 'Keys forgotten'
    

    if __.request.method isnt 'POST'
        new Chocokup.Document 'Key unregistration', kups:{key:forget_kup}, Chocokup.Kups.Tablet
    else
        __.session.clearKeys()
        new Chocokup.Document 'Key unregistration', kups:{key:forgeted_kup}, Chocokup.Kups.Tablet

#### Create Hash
# `create_hash` returns the corresponding sha256 hash from a given key
exports.create_hash = (__) ->
    enter_kup = ->
        form method:"post", ->
            text "Create your Key : "
            input name:"key", type:"password"
            
    entered_kup = ->
        text @params.hash

    if __.request.method isnt 'POST'
        new Chocokup.Document 'Key creation', kups:{key:enter_kup}, Chocokup.Kups.Tablet
    else
        event = new Events.EventEmitter

        source = ''
        __.request.on 'data', (chunk) ->
            source += chunk
        __.request.on 'end', () ->
            fields = require('querystring').parse source

            key = Crypto.createHash('sha256').update(fields.key).digest('hex')
            
            event.emit 'end', new Chocokup.Document 'Key registration', kups:{key:entered_kup}, hash:key, Chocokup.Kups.Tablet
        
        event
        
exports.crash = ->
    while true
        setTimeout ->
            throw new Error('We crashed!!!!!')
        , 100
    'done'
        