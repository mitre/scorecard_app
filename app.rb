# OpenSSL::SSL::VERIFY_PEER = OpenSSL::SSL::VERIFY_NONE

require 'yaml'
require 'sinatra'
require 'sinatra/cross_origin'
require 'fhir_client'
require 'rest-client'
require 'fhir_scorecard'

Dir.glob(File.join(File.dirname(File.absolute_path(__FILE__)),'lib','*.rb')).each do |file|
  require file
end

enable :cross_origin
register Sinatra::CrossOrigin
enable :sessions
set :session_secret, SecureRandom.uuid

puts "Loading terminology..."
FHIR::Terminology.set_terminology_root(File.join(File.dirname(File.absolute_path(__FILE__)),'terminology').to_s)
FHIR::Terminology.load_terminology
puts "Finished loading terminology."

# OPTIONS for CORS preflight requests
options '*' do
  response.headers['Allow'] = 'HEAD,GET,PUT,POST,DELETE,OPTIONS'
  response.headers['Access-Control-Allow-Headers'] = 'X-Requested-With, X-HTTP-Method-Override, Content-Type, Cache-Control, Accept'
  200
end

# Root: redirect to /index
get '/' do
  status, headers, body = call! env.merge("PATH_INFO" => '/index')
end

# The index  displays the available endpoints
get '/index' do
  bullets = {
    '/index' => 'this page',
    '/app' => 'the app (also the redirect_uri after authz)',
    '/launch' => 'the launch url',
    '/fhir' => 'FHIR API',
    '/fhir/metadata' => 'FHIR CapabilityStatement',
    '/fhir/OperationDefinition' => 'FHIR OperationDefinitions',
    '/fhir/OperationDefinition/Patient-completeness' => 'FHIR Completeness Service OperationDefinition',
    '/fhir/$completeness' => 'FHIR Completeness Service Endpoint'
  }
  response = ScorecardApp::Html.new
  body response.open.echo_hash('End Points',bullets).close
end

# This is the primary endpoint of the app and the OAuth2 redirect URL
get '/app' do
  response = ScorecardApp::Html.new
  if params['error']
    if params['error_uri']
      redirect params['error_uri']
    else
      body response.open.echo_hash('Invalid Launch!',params).close
    end
  elsif params['state'] && params['state'] != session[:state]
    body response.open.echo_hash('Invalid Launch State!',params).close
  else
    # Get the OAuth2 token
    puts "App Params: #{params}"

    oauth2_params = {
      'grant_type' => 'authorization_code',
      'code' => params['code'],
      'redirect_uri' => "#{request.base_url}/app",
      'client_id' => session[:client_id]
    }
    puts "Token Params: #{oauth2_params}"
    token_response = RestClient.post(session[:token_url], oauth2_params) #, { 'content-type' => 'application/x-www-form-urlencoded' }
    token_response = JSON.parse(token_response.body)
    puts "Token Response: #{token_response}"
    token = token_response['access_token']
    patient_id = token_response['patient']
    scopes = token_response['scope']

    # Configure the FHIR Client
    client = FHIR::Client.new(session[:fhir_url])
    client.set_bearer_token(token)
    client.default_format = 'application/json+fhir'

    # Get the patient demographics
    patient = client.read(FHIR::Patient, patient_id).resource
    puts "Patient: #{patient.id} #{patient.name}"
    patient_details = patient.to_hash.keep_if{|k,v| ['id','name','gender','birthDate'].include?(k)}

    # Get the patient's conditions
    condition_reply = client.search(FHIR::Condition, search: { parameters: { 'patient' => patient_id, 'clinicalstatus' => 'active' } })
    puts "Conditions: #{condition_reply.resource.entry.length}"

    # Get the patient's medications
    medication_reply = client.search(FHIR::MedicationOrder, search: { parameters: { 'patient' => patient_id, 'status' => 'active' } })
    puts "Medications: #{medication_reply.resource.entry.length}"

    # Assemble the patient record
    record = FHIR::Bundle.new
    record.entry << bundle_entry(patient)
    condition_reply.resource.each do |resource|
      record.entry << bundle_entry(resource)
    end
    medication_reply.resource.each do |resource|
      record.entry << bundle_entry(resource)
    end
    puts "Built the bundle..."

    # Score the bundle
    scorecard = FHIR::Scorecard.new
    scorecard_report = scorecard.score(record.to_json)

    response.open
    response.echo_hash('params',params)
    response.echo_hash('token response',token_response)
    response.echo_hash('patient',patient_details)
    response.echo_hash('scorecard',scorecard_report,['rubric','points','description'])
    body response.close
  end
end

# Helper method to wrap a resource in a Bundle.entry
def bundle_entry(resource)
  entry = FHIR::Bundle::Entry.new
  entry.resource = resource
  entry
end

# This is the launch URI that redirects to an Authorization server
get '/launch' do
  client_id = ScorecardApp::Config.get_client_id(params['iss'])
  auth_info = ScorecardApp::Config.get_auth_info(params['iss'])
  session[:client_id] = client_id
  session[:fhir_url] = params['iss']
  session[:authorize_url] = auth_info[:authorize_url]
  session[:token_url] = auth_info[:token_url]
  puts "Launch Client ID: #{client_id}\nLaunch Auth Info: #{auth_info}\nLaunch Redirect: #{request.base_url}/app"
  session[:state] = SecureRandom.uuid
  oauth2_params = {
    'response_type' => 'code',
    'client_id' => client_id,
    'redirect_uri' => "#{request.base_url}/app",
    'scope' => ScorecardApp::Config.get_scopes(params['iss']),
    'launch' => params['launch'],
    'state' => session[:state],
    'aud' => params['iss']
  }
  oauth2_auth_query = "#{session[:authorize_url]}?"
  oauth2_params.each do |key,value|
    oauth2_auth_query += "#{key}=#{CGI.escape(value)}&"
  end
  puts "Launch Authz Query: #{oauth2_auth_query[0..-2]}"
  response = ScorecardApp::Html.new
  content = response.open.echo_hash('params',params).echo_hash('OAuth2 Metadata',auth_info).close
  redirect oauth2_auth_query[0..-2], content
end

get '/fhir' do
  redirect to('/fhir/metadata')
end

# FHIR CapabilityStatement
get '/fhir/metadata' do
  # Return Static CapabilityStatement
  [200, ScorecardApp::Config::CONTENT_TYPE, ScorecardApp::Config::CAPABILITY_STATEMENT]
end

# FHIR OperationDefinition
get '/fhir/OperationDefinition' do
  # Return Bundle containing static Completeness OperationDefinition
  op = FHIR.from_contents(ScorecardApp::Config::OPERATION_DEFINITION)
  bundle = FHIR::Bundle.new({'type'=>'searchset','total'=>1})
  bundle.entry << bundle_entry(op)
  bundle.entry.last.fullUrl = "#{request.base_url}/fhir/OperationDefinition/Patient-completeness"
  [200, ScorecardApp::Config::CONTENT_TYPE, bundle.to_json]
end

# FHIR Completeness Service OperationDefinition
get '/fhir/OperationDefinition/Patient-completeness' do
  # Return Static Completeness OperationDefinition
  [200, ScorecardApp::Config::CONTENT_TYPE, ScorecardApp::Config::OPERATION_DEFINITION]
end

# FHIR Completeness Service Endpoint
post '/fhir/$completeness' do
  # Check the input
  payload = request.body.read
  begin
    parameters = FHIR.from_contents(payload)
    is_parameters = parameters.is_a?(FHIR::Parameters)
    has_record = is_parameters && !parameters.parameter.empty? && parameters.parameter.length>=1 && parameters.parameter.first.name == 'record'
    has_ig = is_parameters && !parameters.parameter.empty? && parameters.parameter.length==2 && parameters.parameter.last.name == 'ig'
    ig_is_code = has_ig && parameters.parameter.last.valueCode
    use_ig = parameters.parameter.last.valueCode if has_ig && ig_is_code
    record_is_bundle = has_record && parameters.parameter.first.resource.is_a?(FHIR::Bundle)
    valid = is_parameters && has_record && record_is_bundle
    bad_input = !valid
  rescue => e
    puts 'Failed to parse request to $completeness service.'
    puts e
    parameters = nil
    bad_input = true
  end
  if !request.content_type.start_with?('application/fhir+json')
    # We only support JSON
    error = FHIR::OperationOutcome.new
    error.issue << FHIR::OperationOutcome::Issue.new
    error.issue.last.severity = 'error'
    error.issue.last.code = 'not-supported'
    error.issue.last.diagnostics = "The content-type `#{request.content_type}` is not supported. This service only supports `application/fhir+json`."
    response_code = 422
    response_body = error.to_json
  elsif bad_input
    # We only support the $completeness parameters exactly
    error = FHIR::OperationOutcome.new
    error.issue << FHIR::OperationOutcome::Issue.new
    error.issue.last.severity = 'error'
    error.issue.last.code = 'required'
    error.issue.last.diagnostics = 'This operation requires a FHIR Parameters Resource containing a single parameter named `record` containing a FHIR Bundle.'
    response_code = 422
    response_body = error.to_json
  else
    # Calculate completeness scorecard
    scorecard = FHIR::Scorecard.new
    if use_ig == 'us_core'
      scorecard.enable_us_core
    elsif use_ig == 'standard_health_record'
      scorecard.enable_shr
    end
    scorecard_report = scorecard.score(parameters.parameter.first.resource.to_json)

    # Create the response
    reply = FHIR::Parameters.new
    reply.parameter << create_parameter('score', scorecard_report.delete(:points))
    scorecard_report.each do |rubric, data|
      reply.parameter << create_parameter('rubric')
      reply.parameter.last.part << create_parameter('score', data[:points])
      reply.parameter.last.part << create_parameter('category', rubric.to_s)
      reply.parameter.last.part << create_parameter('description', data[:message])
    end

    response_code = 200
    response_body = reply.to_json
  end

  # Return the results
  [response_code, ScorecardApp::Config::CONTENT_TYPE, response_body]
end

def create_parameter(name,value=nil)
  parameter = FHIR::Parameters::Parameter.new
  parameter.name = name
  if value.is_a?(Numeric)
    parameter.valueInteger = value
  else
    parameter.valueString = value
  end
  parameter
end
