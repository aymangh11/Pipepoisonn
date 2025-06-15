# k8s_config.rb
admin = User.find_by_username('root')
private_repo = Project.find_by(name: 'k8s-deployments', namespace_id: admin.namespace_id)

unless private_repo
  raise "Project 'k8s-deployments' not found"
end

kube_config = File.read('/tmp/kubeconfig.yml')

Ci::Variable.create!(
  project: private_repo,
  key: 'KUBE_CONFIG',
  value: kube_config,
  protected: false,
  environment_scope: '*'
)
puts "KUBE_CONFIG variable added to k8s-deployments project."