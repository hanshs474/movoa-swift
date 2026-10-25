Pod::Spec.new do |s|
  s.name             = 'Movoa'
  s.version          = '0.1.0'
  s.summary          = 'Official SDK for Movoa (movoa.ai), the AI video generator with sound.'
  s.description      = 'Unlimited AI video generator with sound: on paid plans the tenth take of a shot costs what the first did, and your first clip is free to make right now. Official Swift SDK for Movoa (movoa.ai): turn a prompt, or a photo as the first frame, into a video clip with sound on your Movoa account and get back the URL of the finished file.'
  s.homepage         = 'https://movoa.ai/?utm_source=cocoapods&utm_medium=package'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = { 'Movoa' => 'support@movoa.ai' }
  s.source           = { :git => 'https://github.com/hanshs474/movoa-swift.git', :tag => s.version.to_s }
  s.ios.deployment_target = '15.0'
  s.osx.deployment_target = '12.0'
  s.swift_versions   = ['5.7']
  s.source_files     = 'Sources/Movoa/**/*.swift'
end
