# oauthd
# http://oauth.io
#
# Copyright (c) 2013 thyb, bump
# For private use only.

async = require 'async'
Mailer = require '../../lib/mailer'
fs = require 'fs'

exports.setup = (callback) ->

	@on 'connect.callback', (data) =>
		@db.timelines.addUse target:'co:' + data.status, (->)
		@db.ranking_timelines.addScore 'p:co:' + data.status, id:data.provider, (->)
		@db.redis.hget 'a:keys', data.key, (e,app) =>
			@db.ranking_timelines.addScore 'a:co:' + data.status, id:app, (->)

	@on 'connect.auth', (data) =>
		@db.timelines.addUse target:'co', (->)
		@db.ranking_timelines.addScore 'p:co', id:data.provider, (->)
		@db.redis.hget 'a:keys', data.key, (e,app) =>
			@db.ranking_timelines.addScore 'a:co', id:app, (->)

	@on 'request', (data) =>
		@db.timelines.addUse target:'req', (->)
		@db.ranking_timelines.addScore 'p:req', id:data.provider, (->)
		@db.redis.hget 'a:keys', data.key, (e,app) =>
			@db.ranking_timelines.addScore 'a:req', id:app, (->)

	@userInvite = (iduser, callback) =>
		prefix = 'u:' + iduser + ':'
		@db.redis.mget [
			prefix+'mail',
			prefix+'key',
			prefix+'validated'
		], (err, replies) =>
			return callback err if err
			if replies[2] == '1'
				return callback new check.Error "not validable"
			options =
				templateName:"mail_validation"
				templatePath:"./app/template/"
				to:
					email: replies[0]
				from:
					name: 'OAuth.io'
					email: 'team@oauth.io'
				subject: 'Validate your OAuth.io Beta account'
			data =
				url: 'https://' + @config.url.host + '/validate/' + iduser + '/' + replies[1]
			mailer = new Mailer options, data
			mailer.send (err, result) =>
				return callback err if err
				@db.redis.set prefix+'validated', '2'
				callback()

	@server.post @config.base_api + '/adm/users/:id/invite', @auth.adm, (req, res, next) =>
		@userInvite req.params.id, @server.send(res, next)

	# get users list
	@server.get @config.base_api + '/adm/users', @auth.adm, (req, res, next) =>
		@db.redis.hgetall 'u:mails', (err, users) =>
			return next err if err
			cmds = []
			for mail,iduser of users
				cmds.push ['get', 'u:' + iduser + ':date_inscr']
				cmds.push ['smembers', 'u:' + iduser + ':apps']
				cmds.push ['get', 'u:' + iduser + ':key']
				cmds.push ['get', 'u:' + iduser + ':validated']
			@db.redis.multi(cmds).exec (err, r) =>
				return next err if err
				i = 0
				for mail,iduser of users
					users[mail] = email:mail, id:iduser, date_inscr:r[i*4], apps:r[i*4+1], key:r[i*4+2], validated:r[i*4+3]
					i++
				res.send users
				next()

	# get app info with ID
	@server.get @config.base_api + '/adm/app/:id', @auth.adm, (req, res, next) =>
		id_app = req.params.id
		prefix = 'a:' + id_app + ':'
		cmds = []
		cmds.push ['mget', prefix + 'name', prefix + 'key']
		cmds.push ['smembers', prefix + 'domains']
		cmds.push ['keys', prefix + 'k:*']

		@db.redis.multi(cmds).exec (err, results) ->
			return next err if err
			app = id:id_app, name:results[0][0], key:results[0][1], domains:results[1], providers:( result.substr(prefix.length + 2) for result in results[2] )
			res.send app
			next()

	# delete a user
	@server.del @config.base_api + '/adm/users/:id', @auth.adm, (req, res, next) =>
		@db.users.remove req.params.id, @server.send(res, next)

	# get any statistics
	@server.get new RegExp('^' + @config.base_api + '/adm/stats/(.+)'), @auth.adm, (req, res, next) =>
		async.parallel [
			(cb) => @db.timelines.getTimeline req.params[0], req.query, cb
			(cb) => @db.timelines.getTotal req.params[0], cb
		], (e, r) ->
			return next e if e
			res.send total:r[1], timeline:r[0]
			next()

	# regenerate all private keys
	@server.get @config.base_api + '/adm/secrets/reset', @auth.adm, (req, res, next) =>
		@db.redis.hgetall 'a:keys', (e, apps) =>
			return next e if e
			mset = []
			for k,id of apps
				mset.push 'a:' + id + ':secret'
				mset.push @db.generateUid()
			@db.redis.mset mset, @server.send(res,next)

	# refresh rankings
	@server.get @config.base_api + '/adm/rankings/refresh', @auth.adm, (req, res, next) =>
		providers = {}
		@db.redis.hgetall 'a:keys', (e, apps) =>
			return next e if e
			tasks = []
			for k,id of apps
				do (id) => tasks.push (cb) =>
					@db.redis.keys 'a:' + id + ':k:*', (e, keysets) =>
						return cb e if e
						for keyset in keysets
							prov = keyset.match /^a:.+?:k:(.+)$/
							continue if not prov?[1]
							providers[prov[1]] ?= 0
							providers[prov[1]]++
						@db.rankings.setScore 'a:k', id:id, val:keysets.length, cb
			async.parallel tasks, (e) =>
				return next e if e
				for p,keysets of providers
					@db.rankings.setScore 'p:k', id:p, val:keysets, (->)
				res.send @check.nullv
				next()

	# get a ranking
	@server.post @config.base_api + '/adm/ranking', @auth.adm, (req, res, next) =>
		@db.ranking_timelines.getRanking req.body.target, req.body, @server.send(res, next)

	# get a ranking related to apps
	@server.post @config.base_api + '/adm/ranking/apps', @auth.adm, (req, res, next) =>
		@db.ranking_timelines.getRanking req.body.target, req.body, (e, infos) =>
			return next e if e
			cmds = []
			for info in infos
				cmds.push ['get', 'a:' + info.name + ':name']
				cmds.push ['smembers', 'a:' + info.name + ':domains']
				# ... add more ? domains ? owner ?
			@db.redis.multi(cmds).exec (e, r) ->
				infos[i].name = r[i*2] + ' (' + r[i*2+1].join(', ') + ')' for i of infos
				res.send infos
				next()

	# get provider list
	@server.get @config.base_api + '/adm/wishlist', @auth.adm, (req, res, next) =>
		@db.wishlist.getList full:true, @server.send(res, next)

	@server.del @config.base_api + '/adm/wishlist/:provider', @auth.adm, (req, res, next) =>
		@db.wishlist.remove req.params.provider, @server.send(res, next)

	@server.post @config.base_api + '/adm/wishlist/setStatus', @auth.adm, (req, res, next) =>
		@db.wishlist.setStatus req.body.provider, req.body.status , @server.send(res, next)

	# plans
	@server.post @config.base_api + '/adm/plan/create', @auth.adm, (req, res, next) =>
		@db.pricing.createOffer req.body, @server.send(res, next)

	@server.get @config.base_api + '/adm/plan', @auth.adm, (req, res, next) =>
		@db.pricing.getOffersList @server.send(res, next)

	@server.del @config.base_api + '/adm/plan/:name', @auth.adm, (req, res, next) =>
		@db.pricing.removeOffer req.params.name, @server.send(res, next)


	#@server.post @config.base_api + '/adm/plan/update/:amount/:name/:currency/:interval', @auth.adm, (req, res, next) =>
	#	@db.pricing.updateOffer req.params.amount, req.params.name, req.params.currency, req.params.interval, @server.send(res, next)

	@server.post @config.base_api + '/adm/plan/update', @auth.adm, (req, res, next) =>
		@db.pricing.updateStatus req.body.name, req.body.currentStatus, @server.send(res, next)

	redisScripts =
		appsbynewusers: @check start:'int', end:['int', 'none'], (data, callback) =>
			start = Math.floor(data.start)
			end = Math.floor(data.end || (new Date).getTime() / 1000)
			return callback new @check.Error 'start', 'start must be > 01/06/2013' if start < 1370037600 # 01/06/2013 00:00:00
			return callback new @check.Error 'start must be < end !' if end - start < 0
			return callback new @check.Error 'time interval must be within 3 months' if end - start > 3600*24*93
			fs.readFile __dirname + '/lua/appsbynewusers.lua', 'utf8', (err, script) =>
				@db.redis.eval script, 0, start*1000, end*1000, (e,r) ->
					return callback e if e
					r[1][i] /= 100 for i of r[1]
					return callback null, r

	@server.get @config.base_api + '/adm/scripts/appsbynewusers', @auth.adm, (req, res, next) =>
		redisScripts.appsbynewusers req.params, @server.send(res, next)

	callback()