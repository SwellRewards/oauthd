async = require 'async'

module.exports = (app) ->
	app.controller 'HomeCtrl', ['$scope', '$state', '$rootScope', 'UserService', 'AppService',
		($scope, $state, $rootScope, UserService, AppService) ->
			$scope.providers = {}
			$scope.loadingApps = true

			$scope.count = (object) ->
				count = 0
				for k,v of object
					count++
				return count

			AppService.all()
				.then (apps) ->
					$scope.apps = apps
					async.eachSeries apps, (app, next) ->
						AppService.get app.key
							.then (app_data) ->
								for j of app_data
									app[j] = app_data[j]
									
								for k,v of app_data.keysets
									$scope.providers[v] = true
								next()
							.fail (e) ->
								console.log e
								next()
					, (err) ->
						$scope.$apply()
				.fail (e) ->
					console.log e
				.finally () ->
					$scope.loadingApps = false
					$scope.$apply()

	]