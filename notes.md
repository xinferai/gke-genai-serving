# Lab notes: the "why" behind each choice

This is a POC, not production. Write each answer in your own words once you have seen it happen.

## Session 1: Terraform and the cluster

1. Where does the state live, and what stops two people from applying at the same time?
2. Why remove the default node pool and manage each pool as its own resource?
3. What do the pods and services ranges do, and how does the pods range limit how many nodes the cluster can have?
4. Why private nodes, and how do they still pull images and reach Google APIs?
5. What does Workload Identity replace, and what is its AWS equivalent?
6. Which changes would replace the cluster instead of updating it, and where does the plan say so?
7. Someone changed the cluster in the console. How do you find that, and what do you do about it?
8. A resource was renamed in the code, or built by hand outside Terraform. How do you avoid destroying and recreating it?
