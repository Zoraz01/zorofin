using Tizen.Flutter.Embedding;
using Tizen.System;
using System.Text.RegularExpressions;

namespace Runner
{
    public class App : FlutterApplication
    {
        protected override void OnCreate()
        {
            base.OnCreate();

            GeneratedPluginRegistrant.RegisterPlugins(this);

            // Keep the commercial model name local. Only this documented UHD
            // family opts into HDR; an absent or internal model code falls back.
            var channel = new MethodChannel("org.zorofin.tv/display");
            channel.SetMethodCallHandler(call => {
                if (call.Method != "isQ80B") return false;
                return Information.TryGetValue("http://tizen.org/system/model_name", out string model)
                    && model != null && Regex.IsMatch(model, @"^Q[NAE](55|65|75|85)Q80B[A-Z0-9]{0,8}$",
                        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
            });
        }

        static void Main(string[] args)
        {
            var app = new App();
            app.Run(args);
        }
    }
}
