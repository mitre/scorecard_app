# Scorecard App
Scorecard App is a
- [SMART-on-FHIR App](http://smarthealthit.org/smart-on-fhir/) that computes a scorecard for an HL7&reg; FHIR&reg; Patient Record (represented as a Bundle).
- FHIR STU3 (v1.8) microservice that only supports a single Operation named `$completeness` that scores a patient record. JSON support only.

## Setup
```
git clone https://github.com/mitre/scorecard_app.git
bundle install
bundle exec ruby app.rb
```

## FHIR $completeness microservice

Access the FHIR microservice at `http://localhost:4567/fhir`

The FHIR microservice includes a `CapabilityStatement` at `/metadata` and a single `OperationDefinition` at `/OperationDefinition/$completeness` which is executable via `POST` at `/$completeness`.

A sample request for the microservice is available in `/test/sample-request-parameters.json` and should be submitted with an HTTP content-type header of `application/fhir+json`.

You can optionally enable Implementation Guide (IG) validation of the submitted record using the `ig` parameter. Allowable codes are `us_core` and `standard_health_record`.

## SMART-on-FHIR App

Access HTML at `http://localhost:4567`

The SMART launch and app urls are `http://localhost:4567/launch` and `http://localhost:4567/app` respectively.

### Configuring Client ID and Scopes (required for SMART app)
Use of the SMART-on-FHIR app requires that OAuth2 client IDs and scopes for different FHIR servers are stored in the
`config.yml` file, so the deployed app can be used with multiple FHIR server implementations.

Each entry under `client_id` and `scopes` should be a unique substring within
the FHIR server URL (for example, `cerner` or `epic`), with the value being the
associated client ID to use or OAuth2 scopes to request.

### Configuring Terminology (optional)
The Scorecard App and microservice can optionally use terminology data. To configure the terminology data, follow these [instructions](https://github.com/fhir-crucible/fhir_scorecard#optional-terminology-support).

### Deploying to AWS Elastic Beanstalk (optional)
Install the AWS Elastic Beanstalk Command Line Interface.
For example, on Mac OS X:
```
brew install awsebcli
```
Build and deploy the app:
```
bundle install
eb init
eb create scorecard-app-dev --sample
eb deploy
```

### Launching the SMART-on-FHIR App
- Using Cerner Millenium
  1. Create an account on [code.cerner.com](https://code.cerner.com)
  - Register a "New App"
    - Launch URI: `[deployed endpoint]/launch`
    - Redirect URI: `[deployed endpoint]/app`
    - App Type: `Provider`
    - FHIR Spec: `dstu2_patient`
    - Authorized: `Yes`
    - Scopes: _select all the Patient Scopes_
  - Select your App under "My Apps"
  - Follow the directions and "Begin Testing"
- Using Epic
  1. Create an account on [open.epic.com](https://open.epic.com).
  - Navigate to the [Launchpad](https://open.epic.com/Launchpad/Oauth2Sso).
  - Enter the details:
    - Launch URL: `[deployed endpoint]/launch`
    - Redirect URL: `[deployed endpoint]/app`
  - Click "Launch App"

Errors encountered during launch are probably associated with improper
configuration of the client ID and scopes.

## License

Copyright 2016 The MITRE Corporation

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at
```
http://www.apache.org/licenses/LICENSE-2.0
```
Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
