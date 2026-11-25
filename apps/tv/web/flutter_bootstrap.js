{{flutter_js}}
{{flutter_build_config}}

const tvEngineConfig = {
    renderer: 'canvaskit',
    canvasKitBaseUrl: 'canvaskit/',
    canvasKitVariant: 'full'
};
_flutter.loader.load({
  config: tvEngineConfig,
  onEntrypointLoaded: async function(engineInitializer) {
    try {
      const runner = await engineInitializer.initializeEngine(tvEngineConfig);
      await runner.runApp();
      document.getElementById('loading')?.remove();
    } catch (_) {
      document.getElementById('loading').textContent = 'Unable to start. Close Zorofin and try again.';
    }
  }
}).catch(function() {
  document.getElementById('loading').textContent = 'Unable to start. Close Zorofin and try again.';
});
