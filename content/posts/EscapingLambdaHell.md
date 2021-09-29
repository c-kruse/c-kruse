---
title: Escaping Lambda Choreography Hell
description: What if writing orchestrated workflows with AWS Step Functions was easier than choreographed implicit workflows?
author: Christian Kruse
date: 2021-09-27T19:43:55-07:00
draft: false
tags:
    - DevEx
    - Serverless
---


I have a theory that there are many choreographed AWS Lambda functions out there in the world doing asynchronous background work that would be better served by a managed central orchestration layer, and that a better developer experience on top of AWS Step Functions would make writing these workflows faster, cheaper and more sustainable than the choreographed version I frequently see.


## The Choreographed Lambda Workflow

First, what do I mean when I describe choreographed AWS Lambda functions, where they might be a good fit, and where there's likely dragons. When I say "choreographed lambda(s)" I mean one or multiple AWS Lambdas designed to both perform work AND invoke another function. This can take a few forms, either directly calling Invoke on a function with a new input, or by writing to one of the AWS managed services neatly integrated with AWS Lambda (such as S3, SNS, SQS, etc.) with the intention of instructing the next lambda function in the chain to do more work. I have developed and several systems this way, and have seen many others that follow this pattern. A good case could probably be made that this pattern is not inherently bad. Well designed systems using choreographed lambda functions can be performant, cheap, relatively sustainable. I find this pattern especially useful when performance and scalability design concerns are more important that durability or correctness. The downside to choreographed lambdas is that they can lead to some pretty grim systems.


{{< figure src="/postmedia/Lambda Choreography Chaos.png" title="Exagerated Example of Lambda Choreography Hell." >}}

I have personally witnessed horror shows of lambdas chained together in implicit workflows using the flavor-of-the-day transport (be it s3, sns, sqs, or dynamodb stream) to deliver a contract-less blob of json to the next function in the chain. As a system like this grows, it gets frustrating to maintain and near impossible to debug. Enormous effort goes into keeping the contracts between lambda functions consistent, passing some form of trace context between functions, updating chaotic architecture diagrams, and setting up elaborate local development environments to test the choreographed flow end to end.

## Why do so many teams fall into choreographed lambda hell?

If choreographed lambdas gone unchecked can become such a burden, how do development teams get sucked down this design path when there is a managed workflow orchestrator that could save them the pain? I believe that teams go down this road because it is the current path of least resistance. In order to adopt AWS Step Functions teams have first had to tackle the learning curve of Amazon States Language, the JSON based DSL that drives AWS Step Functions. Once Step Function state machines are defined teams are taxed to maintain these blobs of JSON alongside thier code, which can be difficult to validate and near impossible to test locally. Finally, debugging takes and extrordanary amount of context switching between buiseness logic, the state language specification, and potentially some declarative IaC specification like CloudFormation or Terraform when trying fully understand a workflow. A glimmer of hope in this problem space that has been getting a lot of attention lately is the Cloud Development Kit (CDK). CDKs like Pulumi, AWS, Terraform CDK to give developers the ability express their infrastructure in the programming environment of their choice. CDK should spare developers half of this context switch by keeping the expression of the infrastructure and their application's code in the same programming environment and potentially adding some abstractions on top of it. However, the buiseness logic and IaC still remain functionally seperate concepts that need reconsiled.


## How could we do better?

Recently I ran into the amazing Shawn "swyx" Wang's "The Self Provisioning Runtime" [article](https://www.swyx.io/self-provisioning-runtime/) and the work being done at [temporal.io](https://temporal.io). This got me thinking about how the advancements in CDKs could be combined with a temporal-inspired wrapper in order to allow developers to describe a serverless workflow with their buisness logic in an intuitive manner.

What if we could write something like this:
```
type MyUserContext struct {
    Name string,
    Email string,
    TimesReminded int,
}

func SendEmailToUser(context.Context, MyUserContext) (MyUserContext, error) {...}

func RemindUserWorkflow(ctx workflow.Context) error {
    wf := workflow.New(workflow.WithRetries(5), workflow.BackoffExponential)
    wf.Begin("Wait one hour", workflow.Wait(time.Hour * 2))
      .Then("First reminder", SendEmailToUser)
      .Then("Wait one day", workflow.Wait(time.Day * 1))
      .Then("Second reminder", SendEmailToUser)
}
```

Instead of this:
```
// Fictional CDK IaC
fn := lambda.Function("remindUser", {
    Code: lambda.BundleGoFunction(".", "./lambda/reminduser.go")
})
sfn.StateMachine("remindUserStateMachine",
    `{
        "StartAt": "Begin",
        "States": {
            "Begin": {
                "Type": "Wait",
                "Hours": 2,
                "Next": "FirstReminder"
            },
            "FirstReminder": {
                "Begin": {
                    "Type": "Task"
                    "LambdaARN": "{{remindUser.ARN}}"
                    "Next": "SecondReminder"
                }
            },
            ...
        }
    }`
)

// lambda/reminduser.go
package main
...
func main() {
    lambda.Start(SendEmailToUser)
}

func SendEmailToUser(context.Context, MyUserContext) (MyUserContext, error) {...}
```


**Note:** I speak of my experience working on these using the AWS ecosystem, but suspect this may be a more widely applicable pattern in the serverless space today - I would be really curious to hear if developers on other cloud providers relate to this at all.
